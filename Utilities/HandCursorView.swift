import AppKit
import SwiftUI

// MARK: - HandCursorView
// A transparent NSView overlay that shows the open hand cursor over the entire canvas.

struct HandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> HandCursorNSView {
        let v = HandCursorNSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        return v
    }

    func updateNSView(_ nsView: HandCursorNSView, context: Context) {}
}

final class HandCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // Pass through all mouse events so Zoomable gestures still work
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
