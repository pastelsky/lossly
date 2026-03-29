import SwiftUI
import AppKit

// MARK: - VisualEffectView
// Wraps NSVisualEffectView to bring native macOS vibrancy into SwiftUI.
// Use .sidebar material for the sidebar panel.

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material     = material
        view.blendingMode = blendingMode
        view.state        = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material     = material
        nsView.blendingMode = blendingMode
        nsView.state        = state
    }
}

// MARK: - View Extension for convenience

extension View {
    /// Applies the native macOS sidebar vibrancy background.
    func sidebarVibrancy() -> some View {
        background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }

    /// Applies a general window-behind vibrancy (e.g. for toolbars).
    func windowVibrancy(material: NSVisualEffectView.Material = .headerView) -> some View {
        background(VisualEffectView(material: material, blendingMode: .behindWindow))
    }
}
