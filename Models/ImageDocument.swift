import SwiftUI
import UniformTypeIdentifiers
import Observation

// MARK: - CompressionMode

enum CompressionMode: String, CaseIterable {
    case auto   = "Auto"
    case manual = "Manual"
}

// MARK: - ImageDocument

@MainActor
@Observable
final class ImageDocument: @preconcurrency ReferenceFileDocument {

    // MARK: ReferenceFileDocument conformance

    static var readableContentTypes: [UTType] { [.png] }
    static var writableContentTypes: [UTType] { [.png] }

    // MARK: Source image

    var sourceImageData: Data?
    var sourceImage: NSImage?

    // MARK: Quantized result

    var quantizedImage: NSImage?
    var quantizedData: Data?
    var isProcessing: Bool = false
    var processingError: String?

    // MARK: Mode

    var compressionMode: CompressionMode = .auto { didSet { scheduleQuantization() } }

    // MARK: Auto mode settings

    /// Single quality knob 0–100. Maps to pngquant --quality (q-10)-(q+10).
    var autoQuality: Int = 75 { didSet { scheduleQuantization() } }  // matches step 3/4 (75)

    // MARK: Manual mode settings

    var selectedQuantizerIndex: Int = 0 { didSet { scheduleQuantization() } }

    /// Number of colors (2–256, or 257 = "true color" / passthrough)
    var numberOfColors: Int = 256 { didSet { scheduleQuantization() } }

    /// Speed 1 (best) to 11 (fastest). Default 3.
    var speed: Int = 3 { didSet { scheduleQuantization() } }

    /// Posterize: 0 = off, 1–4 = bits to truncate
    var posterizeBits: Int = 0 { didSet { scheduleQuantization() } }

    /// Whether to run oxipng DEFLATE optimization pass after quantization
    var deflateOptimizationEnabled: Bool = true { didSet { scheduleQuantization() } }

    // MARK: Shared settings

    var ditheringEnabled: Bool = true { didSet { scheduleQuantization() } }

    // MARK: Resize settings

    /// Resize scale 1–100 percent. 100 = original size (no resize).
    var resizePercent: Int = 100 { didSet { scheduleQuantization() } }

    /// Computed output dimensions based on resizePercent
    var resizedWidth: Int {
        guard let img = sourceImage else { return 0 }
        return max(1, Int(img.size.width * Double(resizePercent) / 100.0))
    }

    var resizedHeight: Int {
        guard let img = sourceImage else { return 0 }
        return max(1, Int(img.size.height * Double(resizePercent) / 100.0))
    }

    // MARK: Display settings

    var showOriginal: Bool = false
    var showZebra: Bool = false {
        didSet {
            if showZebra { computeZebraOverlay() }
            else { zebraOverlay = nil }
        }
    }
    var zebraOverlay: NSImage?
    var zoomLevel: Double = 1.0
    var selectedBackground: BackgroundStyle = BackgroundStyle.all[0]

    // MARK: File sizes

    var sourceFileSize: Int = 0
    var quantizedFileSize: Int = 0
    var sourceFilename: String = ""
    var sourceDirectoryURL: URL?

    var compressionRatio: Double {
        guard sourceFileSize > 0 else { return 1.0 }
        return Double(quantizedFileSize) / Double(sourceFileSize)
    }

    // MARK: Derived helpers

    var errorMessage: String? { processingError }

    var selectedQuantizer: any Quantizer {
        let all = QuantizerRegistry.all
        return selectedQuantizerIndex < all.count ? all[selectedQuantizerIndex] : all[0]
    }

    /// Bit-depth slider value (1…9) <-> numberOfColors (2…256+)
    var colorsBitDepth: Double {
        get {
            if numberOfColors > 256 { return 9 }
            if numberOfColors <= 2  { return 1 }
            return log2(Double(numberOfColors)).rounded()
        }
        set {
            let v = Int(newValue)
            if v > 8      { numberOfColors = 257 }
            else if v <= 1 { numberOfColors = 2 }
            else          { numberOfColors = Int(pow(2.0, Double(v)).rounded()) }
        }
    }

    var colorsLabel: String {
        if numberOfColors > 256 { return "2²⁴" }
        return "\(numberOfColors)"
    }

    // MARK: Effective parameters (used by quantization engine)

    var effectiveQualityRange: ClosedRange<Int> {
        switch compressionMode {
        case .auto:
            let lo = max(0, autoQuality - 10)
            let hi = min(100, autoQuality + 10)
            return lo...hi
        case .manual:
            if numberOfColors >= 256 {
                // At 256+ colors (including true color/passthrough), use high quality
                return 90...100
            }
            // Map color count (2-255) to quality range (0-100), clamped strictly to 0-100
            let q = Int(Double(numberOfColors - 2) / Double(255 - 2) * 100.0)
            let lo = max(0, q - 5)
            let hi = min(100, q + 5)
            // Ensure lo <= hi (can happen at extremes)
            return min(lo, hi)...max(lo, hi)
        }
    }

    var effectiveSpeed: Int {
        compressionMode == .auto ? 3 : speed
    }

    var effectivePosterize: Int {
        compressionMode == .auto ? 0 : posterizeBits
    }

    var effectiveQuantizerIndex: Int {
        compressionMode == .auto ? 0 : selectedQuantizerIndex  // Auto always uses pngquant
    }

    var effectiveQuantizer: any Quantizer {
        let all = QuantizerRegistry.all
        return effectiveQuantizerIndex < all.count ? all[effectiveQuantizerIndex] : all[0]
    }

    // MARK: Internal

    private var currentVersionID: String = ""
    private var quantizationTask: Task<Void, Never>?

    // MARK: Init

    init() {}

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sourceImageData = data
        sourceImage = NSImage(data: data)
        sourceFileSize = data.count
    }

    nonisolated func snapshot(contentType: UTType) throws -> Data { Data() }

    nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    // MARK: Load from drag-drop

    func load(url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }
        sourceImageData = data
        sourceImage = NSImage(data: data)
        sourceFileSize = data.count
        sourceFilename = url.deletingPathExtension().lastPathComponent
        sourceDirectoryURL = url.deletingLastPathComponent()
        quantizedData = nil
        quantizedImage = nil
        quantizedFileSize = 0
        currentVersionID = ""
        scheduleQuantization()
    }

    // MARK: Quantization scheduling

    func scheduleQuantization() {
        guard let data = sourceImageData else { return }

        let q = effectiveQuantizer
        let quality = effectiveQualityRange
        let dither = ditheringEnabled
        let spd = effectiveSpeed
        let post = effectivePosterize
        // Auto mode always runs DEFLATE re-pack; Manual mode respects the toggle
        let deflate = compressionMode == .auto ? true : deflateOptimizationEnabled
        // Include deflate flag in version ID so toggling it invalidates the cache
        let resize = resizePercent
        let baseID = q.versionID(quality: quality, dithering: dither, speed: spd, posterize: post)
        let versionID = baseID + ":ox\(deflate ? 1 : 0):rs\(resize)"

        guard versionID != currentVersionID else { return }

        let quantizerID = q.id
        quantizationTask?.cancel()

        quantizationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            let resolvedQ = QuantizerRegistry.all.first { $0.id == quantizerID } ?? QuantizerRegistry.all[0]
            await self.runQuantization(data: data, quantizer: resolvedQ,
                                       quality: quality, dither: dither,
                                       speed: spd, posterize: post,
                                       deflate: deflateOptimizationEnabled,
                                       resizePercent: resize,
                                       versionID: versionID)
        }
    }

    private func runQuantization(
        data: Data, quantizer: any Quantizer,
        quality: ClosedRange<Int>, dither: Bool,
        speed: Int, posterize: Int, deflate: Bool,
        resizePercent: Int, versionID: String
    ) async {
        isProcessing = true
        processingError = nil

        do {
            // Resize first if needed
            let inputData: Data
            if resizePercent < 100, let resized = Self.resizeImageData(data, percent: resizePercent) {
                inputData = resized
            } else {
                inputData = data
            }

            let result = try await QuantizationService.shared.quantize(
                data: inputData, quantizer: quantizer,
                quality: quality, dither: dither,
                speed: speed, posterize: posterize,
                deflate: deflate
            )
            guard !Task.isCancelled else { return }
            currentVersionID = versionID
            quantizedData = result
            quantizedFileSize = result.count
            quantizedImage = NSImage(data: result)
            if showZebra { computeZebraOverlay() }
        } catch {
            guard !Task.isCancelled else { return }
            processingError = error.localizedDescription
        }

        isProcessing = false
    }

    // MARK: Save

    func saveQuantized(to url: URL) async throws {
        guard let data = quantizedData ?? sourceImageData else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Helpers

    var sourceData: Data? { sourceImageData }

    var suggestedFilename: String {
        guard !sourceFilename.isEmpty else { return "optimized.png" }
        return "\(sourceFilename)-optimized.png"
    }

    func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024        { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: Zebra diff overlay

    /// Computes a semi-transparent diagonal-stripe overlay highlighting pixels
    /// that differ between source and quantized images.
    private func computeZebraOverlay() {
        guard let srcData = sourceImageData,
              let qData = quantizedData,
              let srcCG = cgImageFrom(srcData),
              let qCG = cgImageFrom(qData) else {
            zebraOverlay = nil
            return
        }

        let w = srcCG.width
        let h = srcCG.height

        // If sizes differ (resize active), scale quantized to match source for comparison
        let qScaled: CGImage
        if qCG.width != w || qCG.height != h {
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                zebraOverlay = nil; return
            }
            ctx.interpolationQuality = .high
            ctx.draw(qCG, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { zebraOverlay = nil; return }
            qScaled = scaled
        } else {
            qScaled = qCG
        }

        // Get pixel data for both
        guard let srcProvider = srcCG.dataProvider, let srcRaw = srcProvider.data,
              let qProvider = qScaled.dataProvider, let qRaw = qProvider.data else {
            zebraOverlay = nil; return
        }

        let srcPtr = CFDataGetBytePtr(srcRaw)!
        let qPtr = CFDataGetBytePtr(qRaw)!
        let pixelCount = w * h

        // Build diff mask: true where any channel differs by > threshold
        let threshold: UInt8 = 8
        var mask = [Bool](repeating: false, count: pixelCount)
        for i in 0..<pixelCount {
            let off = i * 4
            let dr = abs(Int(srcPtr[off]) - Int(qPtr[off]))
            let dg = abs(Int(srcPtr[off+1]) - Int(qPtr[off+1]))
            let db = abs(Int(srcPtr[off+2]) - Int(qPtr[off+2]))
            let da = abs(Int(srcPtr[off+3]) - Int(qPtr[off+3]))
            if dr > Int(threshold) || dg > Int(threshold) || db > Int(threshold) || da > Int(threshold) {
                mask[i] = true
            }
        }

        // Create zebra overlay: thin diagonal lines + outline where mask is true
        let lineSpacing = max(6, w / 80)   // Space between lines scales with image
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            zebraOverlay = nil; return
        }

        // Dark magenta color — poppy but professional
        let lineR: UInt8 = 200
        let lineG: UInt8 = 30
        let lineB: UInt8 = 120
        let lineA: UInt8 = 180   // ~70% opacity for lines
        let outlineA: UInt8 = 200 // ~78% opacity for outlines

        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: pixelCount * 4)

        // First pass: thin diagonal lines inside masked areas
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let off = i * 4
                if mask[i] {
                    // Thin line: 1px line every `lineSpacing` pixels diagonally
                    let isLine = ((x + y) % lineSpacing) == 0
                    if isLine {
                        buf[off]   = lineR
                        buf[off+1] = lineG
                        buf[off+2] = lineB
                        buf[off+3] = lineA
                    } else {
                        buf[off] = 0; buf[off+1] = 0; buf[off+2] = 0; buf[off+3] = 0
                    }
                } else {
                    buf[off] = 0; buf[off+1] = 0; buf[off+2] = 0; buf[off+3] = 0
                }
            }
        }

        // Second pass: thin outline at boundaries of masked regions
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if mask[i] {
                    // Check if any neighbor is NOT in the mask (= boundary pixel)
                    let isBorder =
                        (x > 0   && !mask[i - 1]) ||
                        (x < w-1 && !mask[i + 1]) ||
                        (y > 0   && !mask[i - w]) ||
                        (y < h-1 && !mask[i + w])
                    if isBorder {
                        let off = i * 4
                        buf[off]   = lineR
                        buf[off+1] = lineG
                        buf[off+2] = lineB
                        buf[off+3] = outlineA
                    }
                }
            }
        }

        guard let overlayImage = ctx.makeImage() else { zebraOverlay = nil; return }
        zebraOverlay = NSImage(cgImage: overlayImage, size: NSSize(width: w, height: h))
    }

    private func cgImageFrom(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Resize using Core Graphics

    private static func resizeImageData(_ data: Data, percent: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let origW = cgImage.width
        let origH = cgImage.height
        let newW = max(1, origW * percent / 100)
        let newH = max(1, origH * percent / 100)

        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))

        guard let resized = ctx.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, resized, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return mutableData as Data
    }
}
