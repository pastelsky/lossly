import AppKit
import SwiftUI

// MARK: - BackgroundStyle

/// Describes how the transparent-background area behind the image is rendered.
/// Immutable value type — safe to share across concurrency domains.
enum BackgroundStyle: Identifiable, Equatable, Sendable {
    case color(NSColor)
    case checkerboard
    case pattern(name: String, image: NSImage)

    var id: String {
        switch self {
        case .color(let c):
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            c.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)
            return "color_\(Int(r*255))_\(Int(g*255))_\(Int(b*255))"
        case .checkerboard:
            return "checkerboard"
        case .pattern(let name, _):
            return "pattern_\(name)"
        }
    }

    var displayName: String {
        switch self {
        case .color(let c): return colorDisplayName(c)
        case .checkerboard:  return "Checkerboard"
        case .pattern(let name, _): return name
        }
    }

    // MARK: Thumbnail — always called on main thread via SwiftUI

    var thumbnail: Image {
        switch self {
        case .color(let c):      return Image(nsImage: solidColorThumbnail(c))
        case .checkerboard:       return Image(nsImage: checkerboardThumbnail())
        case .pattern(_, let img): return Image(nsImage: patternThumbnail(img))
        }
    }

    // MARK: Private helpers

    private func colorDisplayName(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "Color" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        if r == g && g == b { return r == 0 ? "Black" : r == 255 ? "White" : "Grey \(r)" }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static let thumbSize = CGSize(width: 64, height: 64)

    private func solidColorThumbnail(_ color: NSColor) -> NSImage {
        NSImage(size: Self.thumbSize, flipped: false) { _ in
            color.setFill(); NSRect(origin: .zero, size: Self.thumbSize).fill(); return true
        }
    }

    private func checkerboardThumbnail() -> NSImage {
        let tile: CGFloat = 8
        let size = Self.thumbSize
        return NSImage(size: size, flipped: false) { _ in
            for row in 0..<Int(size.height / tile) {
                for col in 0..<Int(size.width / tile) {
                    let color: NSColor = (row + col) % 2 == 0 ? .white : NSColor(white: 0.78, alpha: 1)
                    color.setFill()
                    NSRect(x: CGFloat(col)*tile, y: CGFloat(row)*tile, width: tile, height: tile).fill()
                }
            }
            return true
        }
    }

    private func patternThumbnail(_ image: NSImage) -> NSImage {
        let size = Self.thumbSize
        return NSImage(size: size, flipped: false) { _ in
            let imgSize = image.size
            let scale = max(size.width / imgSize.width, size.height / imgSize.height)
            let drawW = imgSize.width * scale
            let drawH = imgSize.height * scale
            let rect = CGRect(x: (size.width - drawW)/2, y: (size.height - drawH)/2, width: drawW, height: drawH)
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
    }
}

// MARK: - Default styles (cached at first access)
//
// `defaultStyles()` is @MainActor because NSImage creation must happen on the main thread.

extension BackgroundStyle {

    /// All available background styles. The color/checkerboard styles are hardcoded;
    /// textures are loaded lazily on first access (must be on main thread).
    @MainActor
    static var all: [BackgroundStyle] {
        if _texturesLoaded { return _cachedStyles }
        _cachedStyles.append(contentsOf: loadBundleTextures())
        _texturesLoaded = true
        return _cachedStyles
    }

    @MainActor private static var _texturesLoaded = false
    @MainActor private static var _cachedStyles: [BackgroundStyle] = [
        .checkerboard,
        .color(NSColor(white: 1.0, alpha: 1)),
        .color(NSColor(white: 0.0, alpha: 1)),
        .color(NSColor(white: 0.5, alpha: 1)),
        .color(NSColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 1)),
    ]

    @MainActor
    private static func loadBundleTextures() -> [BackgroundStyle] {
        let names = ["photoshop","461223185","461223192","A_MIXRED","G_IRON3",
                     "nature71","Rustpattern","seawaterfull2","STONE4"]
        let extensions = ["png","jpg","jpeg"]
        
        // Collect URLs first (safe on any thread)
        var results: [BackgroundStyle] = []
        for name in names {
            for ext in extensions {
                if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Textures")
                          ?? Bundle.main.url(forResource: name, withExtension: ext) {
                    // Use NSImage(contentsOf:) which is thread-safe
                    if let img = NSImage(contentsOf: url) {
                        results.append(.pattern(name: name, image: img))
                        break
                    }
                }
            }
        }
        return results
    }
}
