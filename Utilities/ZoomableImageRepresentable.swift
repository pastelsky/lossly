import SwiftUI
import AppKit

// MARK: - ZoomableImageRepresentable

struct ZoomableImageRepresentable: NSViewRepresentable {

    let image: NSImage?
    let originalImage: NSImage?
    let background: Lossly.BackgroundStyle
    let showOriginal: Bool

    @Binding var zoom: Double
    var onFitRequested: Bool
    var onZoomIn: Bool
    var onZoomOut: Bool
    var onActualSize: Bool

    func makeNSView(context: Context) -> ScrollableImageView {
        let sv = ScrollableImageView()
        sv.onZoomChanged = { newZoom in
            DispatchQueue.main.async { zoom = newZoom }
        }
        return sv
    }

    func updateNSView(_ sv: ScrollableImageView, context: Context) {
        let coord = context.coordinator

        // Image — fit on first load
        let imageChanged = sv.image !== image
        if imageChanged {
            sv.image = image
            sv.originalImage = originalImage
        } else {
            sv.originalImage = originalImage
        }

        sv.showingOriginal = showOriginal
        sv.background      = background

        // Action flags — detect rising edge only
        if onFitRequested != coord.lastFit {
            coord.lastFit = onFitRequested
            sv.fitImageToView(animated: true)
        }
        if onZoomIn != coord.lastZoomIn {
            coord.lastZoomIn = onZoomIn
            sv.zoomIn()
        }
        if onZoomOut != coord.lastZoomOut {
            coord.lastZoomOut = onZoomOut
            sv.zoomOut()
        }
        if onActualSize != coord.lastActual {
            coord.lastActual = onActualSize
            sv.zoomActualSize()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFit     = false
        var lastZoomIn  = false
        var lastZoomOut = false
        var lastActual  = false
    }
}
