import AppKit
import Foundation

// MARK: - ImageOptimIntegration

/// Opens the saved file in ImageOptim for further lossless optimization,
/// if ImageOptim is installed on the system.
struct ImageOptimIntegration {

    static let bundleIdentifier = "net.pornel.imageoptim"

    /// Returns true if ImageOptim is available on this system.
    static var isAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Opens `fileURL` in ImageOptim. No-op if ImageOptim is not installed.
    @MainActor
    static func optimize(fileURL: URL) async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        try? await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
    }
}
