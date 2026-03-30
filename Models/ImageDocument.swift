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

    /// Resize scale 1–400 percent. 100 = original size. >100 = AI upscale.
    var resizePercent: Int = 100 { didSet { scheduleQuantization() } }

    // MARK: Upscale settings

    var upscaleModel: UpscaleModel = .general { didSet {
        upscale4xCache = nil  // Invalidate cache when model changes
        if resizePercent > 100 { scheduleQuantization() }
    }}
    var isUpscaling: Bool = false
    var upscaledImage: NSImage?
    var upscaledData: Data?

    /// Upscale the current image using Real-ESRGAN (4x).
    func upscaleImage() {
        guard let data = quantizedData ?? sourceImageData else { return }
        isUpscaling = true
        Task.detached {
            do {
                let result = try await UpscaleService.shared.upscale(imageData: data, model: self.upscaleModel)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.upscaledData = result
                    self.upscaledImage = NSImage(data: result)
                    self.isUpscaling = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isUpscaling = false
                    self?.processingError = error.localizedDescription
                }
            }
        }
    }

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
            if showZebra {
                let srcData = sourceImageData
                let qData = quantizedData
                Task.detached {
                    let overlay = Self.buildZebraOverlay(srcData: srcData, qData: qData)
                    await MainActor.run { [weak self] in self?.zebraOverlay = overlay }
                }
            } else {
                zebraOverlay = nil
            }
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

    /// Analyze the source image and pick the optimal number of palette colors.
    /// Downsamples to 256×256 first for speed, then counts significant colors
    /// using a 5-bit-per-channel histogram (32K buckets, fixed-size array).
    func autoDetectColors() {
        guard let data = sourceImageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

        // Downsample to 256×256 for fast analysis — color distribution is preserved
        let sampleSize = 256
        guard let ctx = CGContext(data: nil, width: sampleSize, height: sampleSize,
                                  bitsPerComponent: 8, bytesPerRow: sampleSize * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        let totalPixels = sampleSize * sampleSize
        guard let ptr = ctx.data?.bindMemory(to: UInt8.self, capacity: totalPixels * 4) else { return }

        // Fixed-size histogram: 5 bits per channel = 32768 buckets (no dictionary overhead)
        var histogram = [Int](repeating: 0, count: 32768)
        for i in 0..<totalPixels {
            let off = i * 4
            let key = (Int(ptr[off] >> 3) << 10) | (Int(ptr[off+1] >> 3) << 5) | Int(ptr[off+2] >> 3)
            histogram[key] += 1
        }

        // Drop colors appearing in < 0.1% of sampled pixels
        let threshold = max(1, totalPixels / 1000)
        var significantColors = 0
        for count in histogram where count >= threshold {
            significantColors += 1
        }

        // Clamp to 2–256 and snap to nearest power of 2
        let clamped = max(2, min(256, significantColors))
        let bits = max(1, Int(ceil(log2(Double(clamped)))))
        let snapped = Int(pow(2.0, Double(bits)))
        numberOfColors = min(256, snapped)
    }

    // MARK: Effective parameters (used by quantization engine)

    var effectiveQualityRange: ClosedRange<Int> {
        switch compressionMode {
        case .auto:
            let lo = max(0, autoQuality - 10)
            let hi = min(100, autoQuality + 10)
            return lo...hi
        case .manual:
            // In manual mode, quality is always 0-100 (let pngquant decide best
            // quality within the color count constraint)
            return 0...100
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

    /// Cache the expensive 4x AI upscale result (reused for 1.5×, 2×, 3×, etc.)
    private var upscale4xCache: Data?

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
        upscale4xCache = nil
        scheduleQuantization()
    }

    // MARK: Quantization scheduling

    func scheduleQuantization() {
        let msg = "[Lossly] scheduleQuantization called (resize=\(resizePercent))"
        NSLog("%@", msg)
        try? msg.appending("\n").write(toFile: "/tmp/lossly_debug.log", atomically: false, encoding: .utf8)
        guard let data = sourceImageData else {
            NSLog("[Lossly] No source data, skipping")
            return
        }

        let q = effectiveQuantizer
        let quality = effectiveQualityRange
        let dither = ditheringEnabled
        let spd = effectiveSpeed
        let post = effectivePosterize
        // Auto mode always runs DEFLATE re-pack; Manual mode respects the toggle
        let deflate = compressionMode == .auto ? true : deflateOptimizationEnabled
        // Include deflate flag in version ID so toggling it invalidates the cache
        let resize = resizePercent
        let colors = numberOfColors
        let baseID = q.versionID(quality: quality, dithering: dither, speed: spd, posterize: post, colors: colors)
        let modelID = resize > 100 ? upscaleModel.rawValue : ""
        let versionID = baseID + ":ox\(deflate ? 1 : 0):rs\(resize):m\(modelID)"

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
                                       colors: colors,
                                       deflate: deflateOptimizationEnabled,
                                       resizePercent: resize,
                                       versionID: versionID)
        }
    }

    private func runQuantization(
        data: Data, quantizer: any Quantizer,
        quality: ClosedRange<Int>, dither: Bool,
        speed: Int, posterize: Int, colors: Int,
        deflate: Bool, resizePercent: Int, versionID: String
    ) async {
        isProcessing = true
        processingError = nil

        do {
            // Resize / upscale if needed
            let inputData: Data
            if resizePercent > 100 {
                // AI upscale: always 4x via Real-ESRGAN, then downsample to target if needed
                let upscaled4x: Data
                if let cached = upscale4xCache {
                    NSLog("[Lossly] Using cached 4x upscale")
                    upscaled4x = cached
                } else {
                    NSLog("[Lossly] Starting AI 4x upscale...")
                    let result = try await UpscaleService.shared.upscale(imageData: data, model: upscaleModel)
                    self.upscale4xCache = result
                    NSLog("[Lossly] AI 4x upscale complete: \(result.count) bytes")
                    upscaled4x = result
                }

                if resizePercent < 400 {
                    // Downsample from 4x to target size
                    let targetW = resizedWidth
                    let targetH = resizedHeight
                    NSLog("[Lossly] Downsampling 4x to %dx%d (%d%%)", targetW, targetH, resizePercent)
                    if let nsImg = NSImage(data: upscaled4x),
                       let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
                       let ctx = CGContext(data: nil, width: targetW, height: targetH,
                                           bitsPerComponent: 8, bytesPerRow: targetW * 4,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.interpolationQuality = .high
                        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                        if let downsampled = ctx.makeImage() {
                            let rep = NSBitmapImageRep(cgImage: downsampled)
                            if let pngData = rep.representation(using: .png, properties: [:]) {
                                inputData = pngData
                            } else {
                                inputData = upscaled4x
                            }
                        } else {
                            inputData = upscaled4x
                        }
                    } else {
                        inputData = upscaled4x
                    }
                } else {
                    inputData = upscaled4x
                }
            } else if resizePercent < 100, let resized = Self.resizeImageData(data, percent: resizePercent) {
                print("[Lossly] Downscaled to \(resizePercent)%: \(resized.count) bytes")
                inputData = resized
            } else {
                inputData = data
            }

            let result = try await QuantizationService.shared.quantize(
                data: inputData, quantizer: quantizer,
                quality: quality, dither: dither,
                speed: speed, posterize: posterize,
                colors: colors, deflate: deflate
            )
            guard !Task.isCancelled else { return }
            let img = NSImage(data: result)
            currentVersionID = versionID
            quantizedData = result
            quantizedFileSize = result.count
            quantizedImage = img
            
            if showZebra {
                let srcData = sourceImageData
                let qData = quantizedData
                Task.detached {
                    let overlay = Self.buildZebraOverlay(srcData: srcData, qData: qData)
                    await MainActor.run { [weak self] in self?.zebraOverlay = overlay }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("[Lossly] ERROR: %@", error.localizedDescription)
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
    /// that differ between source and quantized images. Runs off main thread.
    nonisolated private static func buildZebraOverlay(srcData: Data?, qData: Data?) -> NSImage? {
        guard let srcData, let qData,
              let srcCG = cgImageFromData(srcData),
              let qCG = cgImageFromData(qData) else {
            return nil
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
                return nil
            }
            ctx.interpolationQuality = .high
            ctx.draw(qCG, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            qScaled = scaled
        } else {
            qScaled = qCG
        }

        // Get pixel data for both
        guard let srcProvider = srcCG.dataProvider, let srcRaw = srcProvider.data,
              let qProvider = qScaled.dataProvider, let qRaw = qProvider.data else {
            return nil
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

        // Render zebra at 2x for retina sharpness using pixel buffer
        let scale = 2
        let rw = w * scale
        let rh = h * scale
        let lineSpacing = max(4, w / 150)  // Tight diagonal lines

        guard let ctx = CGContext(data: nil, width: rw, height: rh,
                                  bitsPerComponent: 8, bytesPerRow: rw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // Bright pink, fully opaque
        let lineR: UInt8 = 255
        let lineG: UInt8 = 20
        let lineB: UInt8 = 147
        let lineA: UInt8 = 255  // 100%

        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: rw * rh * 4)

        for ry in 0..<rh {
            for rx in 0..<rw {
                // Map back to source pixel to check mask
                let sx = rx / scale
                let sy = ry / scale
                let mi = sy * w + sx
                let off = (ry * rw + rx) * 4

                if mi < pixelCount && mask[mi] {
                    // Thin diagonal line every lineSpacing pixels (in source space)
                    let isLine = ((sx + sy) % lineSpacing) == 0
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

        guard let overlayImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: overlayImage, size: NSSize(width: w, height: h))
    }

    nonisolated private static func cgImageFromData(_ data: Data) -> CGImage? {
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
