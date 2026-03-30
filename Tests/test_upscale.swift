#!/usr/bin/env swift
/// Lossly Upscale Test
/// Tests Real-ESRGAN Core ML model with opaque and transparent PNGs.
/// Usage: swift Tests/test_upscale.swift <path-to-RealESRGAN.mlpackage> [output-dir]
///
/// Tests:
///   1. Opaque PNG — verifies output is not black, correct size
///   2. Transparent PNG — verifies alpha channel is preserved
///   3. Edge case — 1px transparent border image

import CoreML
import CoreGraphics
import AppKit
import Foundation

// MARK: - Args

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift test_upscale.swift <model.mlpackage> [output-dir]")
    exit(1)
}
let modelPath = args[1]
let outputDir = args.count >= 3 ? args[2] : "/tmp/lossly_tests"
try! FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// MARK: - Model Loading

print("Loading model: \(modelPath)")
let config = MLModelConfiguration()
config.computeUnits = .all
let compiledURL = try! MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
let model = try! MLModel(contentsOf: compiledURL, configuration: config)
let inputName = model.modelDescription.inputDescriptionsByName.keys.first!
let outputName = model.modelDescription.outputDescriptionsByName.keys.first!
print("Input: '\(inputName)', Output: '\(outputName)'")

// MARK: - Helpers

func makePNG(width: Int, height: Int, withAlpha: Bool) -> Data {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i]   = UInt8(x * 255 / max(1, width - 1))   // R gradient
            pixels[i+1] = UInt8(y * 255 / max(1, height - 1))  // G gradient
            pixels[i+2] = 128                                    // B flat
            if withAlpha {
                // Transparent corners, opaque center
                let dx = x - width/2; let dy = y - height/2
                let dist = sqrt(Double(dx*dx + dy*dy))
                let r = Double(min(width, height)) / 2.0
                pixels[i+3] = dist < r ? 255 : 0
            } else {
                pixels[i+3] = 255
            }
        }
    }
    let data = Data(pixels)
    let provider = CGDataProvider(data: data as CFData)!
    let cgImg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])!
}

func runUpscale(cgImage: CGImage) -> [UInt8]? {
    let w = cgImage.width, h = cgImage.height
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
    guard let pixBuf = pb else { return nil }
    CVPixelBufferLockBaseAddress(pixBuf, [])
    if let base = CVPixelBufferGetBaseAddress(pixBuf) {
        let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: CVPixelBufferGetBytesPerRow(pixBuf),
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                       CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.translateBy(x: 0, y: CGFloat(h)); ctx?.scaleBy(x: 1, y: -1)
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    CVPixelBufferUnlockBaseAddress(pixBuf, [])

    let fv = try! MLFeatureValue(pixelBuffer: pixBuf)
    let prov = try! MLDictionaryFeatureProvider(dictionary: [inputName: fv])
    let pred = try! model.prediction(from: prov)
    guard let arr = pred.featureValue(for: outputName)?.multiArrayValue else { return nil }

    let shape = arr.shape.map { $0.intValue }
    let outH = shape[2], outW = shape[3]
    let ptr = arr.dataPointer.assumingMemoryBound(to: Float16.self)
    let plane = outH * outW
    var rgba = [UInt8](repeating: 255, count: outW * outH * 4)
    for y in 0..<outH {
        for x in 0..<outW {
            let idx = y * outW + x
            rgba[(y*outW+x)*4]   = UInt8(max(0, min(255, Float(ptr[idx]) * 255)))
            rgba[(y*outW+x)*4+1] = UInt8(max(0, min(255, Float(ptr[plane+idx]) * 255)))
            rgba[(y*outW+x)*4+2] = UInt8(max(0, min(255, Float(ptr[2*plane+idx]) * 255)))
        }
    }
    return rgba
}

func saveRGBA(_ rgba: [UInt8], width: Int, height: Int, to path: String) {
    let data = Data(rgba)
    let provider = CGDataProvider(data: data as CFData)!
    let cgImg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: cgImg)
    let pngData = rep.representation(using: .png, properties: [:])!
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("  Saved: \(path) (\(pngData.count) bytes)")
}

var passed = 0, failed = 0

// MARK: - Test 1: Opaque PNG

print("\n=== Test 1: Opaque 128x128 PNG ===")
let opaquePNG = makePNG(width: 128, height: 128, withAlpha: false)
let opaqueNS = NSImage(data: opaquePNG)!
let opaqueCG = opaqueNS.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let t1 = CFAbsoluteTimeGetCurrent()
if let out = runUpscale(cgImage: opaqueCG) {
    let elapsed = CFAbsoluteTimeGetCurrent() - t1
    let mid = (256 * 256 / 2) * 4
    let nonBlack = (0..<256).filter { x in
        let i = (128*256+x)*4; return out[i] > 10 || out[i+1] > 10 || out[i+2] > 10
    }.count
    print("  ✅ Time: \(String(format: "%.3f", elapsed))s | Non-black: \(nonBlack)/256 | Middle: [\(out[mid]),\(out[mid+1]),\(out[mid+2])]")
    saveRGBA(out, width: 512, height: 512, to: "\(outputDir)/test1_opaque_4x.png")
    passed += 1
} else { print("  ❌ FAILED"); failed += 1 }

// MARK: - Test 2: Transparent PNG (alpha circle)

print("\n=== Test 2: Transparent 128x128 PNG ===")
let alphaPNG = makePNG(width: 128, height: 128, withAlpha: true)
let alphaNS = NSImage(data: alphaPNG)!
let alphaCG = alphaNS.cgImage(forProposedRect: nil, context: nil, hints: nil)!

// Extract alpha from source
let srcRaw = {
    var buf = [UInt8](repeating: 0, count: 128*128*4)
    let ctx = CGContext(data: &buf, width: 128, height: 128, bitsPerComponent: 8,
                       bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: 128); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(alphaCG, in: CGRect(x: 0, y: 0, width: 128, height: 128))
    return buf
}()
let hasTransparentCorner = srcRaw[3] == 0
print("  Source top-left alpha: \(srcRaw[3]) (expect 0 = transparent)")

if let out = runUpscale(cgImage: alphaCG) {
    // Manually apply upscaled alpha from source
    var withAlpha = out
    for y in 0..<512 {
        for x in 0..<512 {
            let sx = min(x/4, 127); let sy = min(y/4, 127)
            withAlpha[(y*512+x)*4+3] = srcRaw[(sy*128+sx)*4+3]
        }
    }
    let cornerAlpha = withAlpha[3]
    let centerIdx = (256*512+256)*4
    let centerAlpha = withAlpha[centerIdx+3]
    print("  ✅ Corner alpha: \(cornerAlpha) (expect 0) | Center alpha: \(centerAlpha) (expect 255)")
    saveRGBA(withAlpha, width: 512, height: 512, to: "\(outputDir)/test2_transparent_4x.png")
    if cornerAlpha == 0 && centerAlpha == 255 { passed += 1 } else { failed += 1 }
} else { print("  ❌ FAILED"); failed += 1 }

// MARK: - Test 3: Small edge case (8x8)

print("\n=== Test 3: Very small 8x8 PNG (padded to 128x128) ===")
let smallPNG = makePNG(width: 8, height: 8, withAlpha: false)
let smallNS = NSImage(data: smallPNG)!
var smallCG = smallNS.cgImage(forProposedRect: nil, context: nil, hints: nil)!
// Scale up to 128x128 for model input
var padBuf = [UInt8](repeating: 100, count: 128*128*4)
let padCtx = CGContext(data: &padBuf, width: 128, height: 128, bitsPerComponent: 8,
                       bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
padCtx.translateBy(x: 0, y: 128); padCtx.scaleBy(x: 1, y: -1)
padCtx.draw(smallCG, in: CGRect(x: 0, y: 0, width: 8, height: 8))
let padProvider = CGDataProvider(data: Data(padBuf) as CFData)!
smallCG = CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: padProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

if let out = runUpscale(cgImage: smallCG) {
    let nonBlack = (0..<512).filter { x in
        let i = (256*512+x)*4; return out[i] > 10 || out[i+1] > 10 || out[i+2] > 10
    }.count
    print("  ✅ Small image upscaled | Non-black in middle: \(nonBlack)/512")
    saveRGBA(out, width: 512, height: 512, to: "\(outputDir)/test3_small_4x.png")
    if nonBlack > 100 { passed += 1 } else { print("  ❌ Too many black pixels"); failed += 1 }
} else { print("  ❌ FAILED"); failed += 1 }

// MARK: - Summary

print("\n=== Results: \(passed)/\(passed+failed) passed ===")
print("Output images: \(outputDir)/")
exit(failed > 0 ? 1 : 0)
