import Foundation

// MARK: - Quantizer Protocol

/// Represents a PNG lossy-compression strategy backed by an external CLI tool.
protocol Quantizer: AnyObject, Identifiable, Sendable {
    var id: String { get }
    var displayName: String { get }
    var qualityLabel: String { get }
    var supportsDithering: Bool { get }
    var supportsSpeed: Bool { get }
    var supportsPosterize: Bool { get }

    /// Return the executable name and argument list for this quantizer.
    func launchArguments(dither: Bool, quality: ClosedRange<Int>, speed: Int, posterize: Int) -> (executable: String, args: [String])

    /// A stable cache key for the current settings combination.
    func versionID(quality: ClosedRange<Int>, dithering: Bool, speed: Int, posterize: Int) -> String
}

extension Quantizer {
    var supportsDithering: Bool { true }
    var supportsSpeed: Bool { false }
    var supportsPosterize: Bool { false }
    var qualityLabel: String { "Quality" }

    func versionID(quality: ClosedRange<Int>, dithering: Bool, speed: Int, posterize: Int) -> String {
        "\(id):q\(quality.lowerBound)-\(quality.upperBound):d\(dithering ? 1 : 0):s\(speed):p\(posterize)"
    }
}

// MARK: - Pngquant

/// Uses pngquant's --quality min-max mode — the correct, modern way.
/// The algorithm automatically selects the minimum colors needed to hit quality.
/// For 257+ colors (true color/passthrough), uses --quality 100-100 to skip lossy reduction.
final class PngquantQuantizer: Quantizer {
    let id = "pngquant"
    let displayName = "pngquant"
    let supportsSpeed = true
    let supportsPosterize = true

    func launchArguments(dither: Bool, quality: ClosedRange<Int>, speed: Int, posterize: Int) -> (executable: String, args: [String]) {
        var args: [String] = []
        // For passthrough/true color (quality 90-100), use strict 100-100 to prevent lossy reduction
        let qLo = quality.lowerBound
        let qHi = quality.upperBound
        if qLo >= 90 && qHi == 100 {
            args += ["--quality", "100-100"]
        } else {
            args += ["--quality", "\(qLo)-\(qHi)"]
        }
        args += [dither ? "--floyd=1" : "--nofs"]
        args += ["--speed", "\(speed)"]
        if posterize > 0 {
            args += ["--posterize", "\(posterize)"]
        }
        args += ["--force"]
        return ("pngquant", args)
    }
}

// MARK: - Registry

enum QuantizerRegistry {
    static let all: [any Quantizer] = [
        PngquantQuantizer(),
    ]

    static var `default`: any Quantizer { all[0] }
}
