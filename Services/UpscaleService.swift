import CoreML
import CoreImage
import CoreGraphics
import AppKit

// MARK: - UpscaleModel

enum UpscaleModel: String, CaseIterable, Identifiable {
    case general = "General (Fast)"

    var id: String { rawValue }

    var resourceName: String {
        switch self {
        case .general: return "RealESRGAN_general"
        }
    }
}

// MARK: - UpscaleService

/// Upscales images 4x using Real-ESRGAN Core ML model.
/// Uses MultiArray output for correct pixel values.
/// Tile-based with overlap for images larger than 128×128.
final class UpscaleService: @unchecked Sendable {

    static let shared = UpscaleService()

    private var loadedModels: [UpscaleModel: MLModel] = [:]
    private let scaleFactor = 4
    private let tileSize = 128
    private let tilePad = 16

    private init() {}

    enum UpscaleError: Error {
        case modelNotFound, invalidImage, predictionFailed
    }

    // MARK: - Public API

    func upscale(imageData: Data, model upscaleModel: UpscaleModel = .general) async throws -> Data {
        let model = try loadModel(upscaleModel)

        guard let nsImage = NSImage(data: imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw UpscaleError.invalidImage
        }

        let w = cgImage.width
        let h = cgImage.height
        let outW = w * scaleFactor
        let outH = h * scaleFactor
        let innerTile = tileSize - 2 * tilePad
        let hasAlpha = cgImage.alphaInfo != .none &&
                       cgImage.alphaInfo != .noneSkipLast &&
                       cgImage.alphaInfo != .noneSkipFirst

        NSLog("[UpscaleService] Input: %dx%d → Output: %dx%d, hasAlpha=%d", w, h, outW, outH, hasAlpha ? 1 : 0)

        // Render source to top-left RGBA buffer
        guard var srcBuf = cgImageToTopLeftBuffer(cgImage, width: w, height: h) else {
            throw UpscaleError.invalidImage
        }

        // Extract alpha
        var alphaBuf: [UInt8]?
        if hasAlpha {
            var alpha = [UInt8](repeating: 255, count: w * h)
            for i in 0..<(w * h) { alpha[i] = srcBuf[i * 4 + 3] }
            alphaBuf = alpha
            for i in 0..<(w * h) {
                if srcBuf[i * 4 + 3] == 0 {
                    srcBuf[i * 4] = 128; srcBuf[i * 4 + 1] = 128; srcBuf[i * 4 + 2] = 128
                }
            }
        }

        // Output buffer (top-left RGBA)
        var outBuf = [UInt8](repeating: 0, count: outW * outH * 4)

        // Tile loop
        var tileY = 0
        while tileY < h {
            var tileX = 0
            while tileX < w {
                let tileW = min(innerTile, w - tileX)
                let tileH = min(innerTile, h - tileY)

                let srcLeft = max(0, tileX - tilePad)
                let srcTop = max(0, tileY - tilePad)
                let srcRight = min(w, tileX + tileW + tilePad)
                let srcBottom = min(h, tileY + tileH + tilePad)
                let srcW = srcRight - srcLeft
                let srcH = srcBottom - srcTop
                let padLeft = tileX - srcLeft
                let padTop = tileY - srcTop

                // Extract tile into tileSize×tileSize buffer
                var tileBuf = [UInt8](repeating: 128, count: tileSize * tileSize * 4)
                for row in 0..<srcH {
                    for col in 0..<srcW {
                        let si = ((srcTop + row) * w + (srcLeft + col)) * 4
                        let di = (row * tileSize + col) * 4
                        tileBuf[di] = srcBuf[si]; tileBuf[di+1] = srcBuf[si+1]
                        tileBuf[di+2] = srcBuf[si+2]; tileBuf[di+3] = srcBuf[si+3]
                    }
                }

                // Create CGImage from tile, run model
                guard let tileImage = topLeftBufferToCGImage(tileBuf, width: tileSize, height: tileSize),
                      let outTileBuf = try await runModelMultiArray(model, on: tileImage) else {
                    tileX += innerTile; continue
                }

                // Copy inner region to output
                let outTileSize = tileSize * scaleFactor
                let cropLeft = padLeft * scaleFactor
                let cropTop = padTop * scaleFactor
                let copyW = tileW * scaleFactor
                let copyH = tileH * scaleFactor
                let destX = tileX * scaleFactor
                let destY = tileY * scaleFactor

                for row in 0..<copyH {
                    for col in 0..<copyW {
                        let si = ((cropTop + row) * outTileSize + (cropLeft + col)) * 4
                        let di = ((destY + row) * outW + (destX + col)) * 4
                        if si + 3 < outTileBuf.count && di + 3 < outBuf.count {
                            outBuf[di] = outTileBuf[si]; outBuf[di+1] = outTileBuf[si+1]
                            outBuf[di+2] = outTileBuf[si+2]; outBuf[di+3] = outTileBuf[si+3]
                        }
                    }
                }
                tileX += innerTile
            }
            tileY += innerTile
        }

        // Recombine alpha
        if hasAlpha, let alpha = alphaBuf {
            for y in 0..<outH {
                for x in 0..<outW {
                    let sx = min(x / scaleFactor, w - 1)
                    let sy = min(y / scaleFactor, h - 1)
                    outBuf[(y * outW + x) * 4 + 3] = alpha[sy * w + sx]
                }
            }
        }

        guard let outImage = topLeftBufferToCGImage(outBuf, width: outW, height: outH) else {
            throw UpscaleError.predictionFailed
        }
        let rep = NSBitmapImageRep(cgImage: outImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw UpscaleError.predictionFailed
        }
        NSLog("[UpscaleService] Done: %dx%d, %d bytes", outW, outH, pngData.count)
        return pngData
    }

    // MARK: - Core ML (MultiArray output)

    /// Run model and return output as top-left RGBA byte array
    private func runModelMultiArray(_ model: MLModel, on image: CGImage) async throws -> [UInt8]? {
        let inputSize = tileSize

        // Create CVPixelBuffer input
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, inputSize, inputSize, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pixBuf = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixBuf, [])
        if let base = CVPixelBufferGetBaseAddress(pixBuf) {
            let ctx = CGContext(data: base, width: inputSize, height: inputSize,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixBuf),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                          CGImageAlphaInfo.premultipliedFirst.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
        }
        CVPixelBufferUnlockBaseAddress(pixBuf, [])

        // Run prediction
        let fv = try MLFeatureValue(pixelBuffer: pixBuf)
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
        let prediction = try await model.prediction(from: provider)
        let outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "output"

        guard let outArray = prediction.featureValue(for: outputName)?.multiArrayValue else {
            return nil
        }

        // Convert [1, 3, outH, outW] float16 → RGBA bytes (top-left origin)
        let shape = outArray.shape.map { $0.intValue }
        let outH = shape[2], outW = shape[3]
        let ptr = outArray.dataPointer.assumingMemoryBound(to: Float16.self)
        let planeSize = outH * outW

        var rgba = [UInt8](repeating: 255, count: outW * outH * 4)
        for y in 0..<outH {
            for x in 0..<outW {
                let idx = y * outW + x
                let r = UInt8(max(0, min(255, Float(ptr[idx]) * 255.0)))
                let g = UInt8(max(0, min(255, Float(ptr[planeSize + idx]) * 255.0)))
                let b = UInt8(max(0, min(255, Float(ptr[2 * planeSize + idx]) * 255.0)))
                let di = (y * outW + x) * 4
                rgba[di] = r; rgba[di+1] = g; rgba[di+2] = b; rgba[di+3] = 255
            }
        }
        return rgba
    }

    // MARK: - Buffer Helpers

    private func cgImageToTopLeftBuffer(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &buf, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buf
    }

    private func topLeftBufferToCGImage(_ buf: [UInt8], width: Int, height: Int) -> CGImage? {
        let rowBytes = width * 4
        var flipped = [UInt8](repeating: 0, count: buf.count)
        for row in 0..<height {
            let s = row * rowBytes; let d = (height - 1 - row) * rowBytes
            flipped[d..<(d + rowBytes)] = buf[s..<(s + rowBytes)]
        }
        let data = Data(flipped)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private func loadModel(_ upscaleModel: UpscaleModel) throws -> MLModel {
        if let m = loadedModels[upscaleModel] { return m }
        let name = upscaleModel.resourceName
        NSLog("[UpscaleService] Loading model: %@", name)
        guard let modelURL = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: name, withExtension: "mlpackage") else {
            throw UpscaleError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loaded = try MLModel(contentsOf: modelURL, configuration: config)
        loadedModels[upscaleModel] = loaded
        return loaded
    }
}
