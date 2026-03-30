import SwiftUI
import Zoomable

// MARK: - ImagePreviewView

struct ImagePreviewView: View {
    @Bindable var document: ImageDocument
    let background: Lossly.BackgroundStyle
    // Note: userZoom drives .scaleEffect since ryohey/Zoomable has no programmatic zoom API
    @State private var userZoom: CGFloat = 1.0
    @State private var canvasSize: CGSize = .zero
    // Incrementing this resets the Zoomable internal pan/zoom state
    @State private var zoomableResetID: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // ── Canvas ─────────────────────────────────────────────────────
            GeometryReader { geo in
                let _ = geo.size
                ZStack {
                    // Fixed background — never zooms
                    BackgroundCanvasView(style: background)
                        .ignoresSafeArea()

                    // Zoomable image
                    if let displayImg = (document.showOriginal ? document.sourceImage : nil) ?? document.quantizedImage ?? document.sourceImage,
                       let srcImg = document.sourceImage {
                        // Use source image size for framing so layout doesn't jump on resize
                        let frameW = min(srcImg.size.width, geo.size.width * 0.92)
                        let frameH = min(srcImg.size.height, geo.size.height * 0.92)
                        ZStack {
                            Image(nsImage: displayImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: frameW, height: frameH)
                            if document.showZebra, !document.showOriginal, let zebra = document.zebraOverlay {
                                Image(nsImage: zebra)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: frameW, height: frameH)
                                    .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(userZoom, anchor: .center)
                        .zoomable(minZoomScale: 0.05, maxZoomScale: 32, doubleTapZoomScale: 2)
                        .id(zoomableResetID)
                    } else {
                        dropHint
                    }
                }
                // Full-area hand cursor overlay
                .overlay(HandCursorView())
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Bottom bar ─────────────────────────────────────────────────
            bottomBar
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    saveOptimizedImage()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .help("Export optimized PNG…")
                .disabled(document.quantizedImage == nil && document.sourceImage == nil)
            }
        }
    }

    // MARK: - Drop hint

    // MARK: - Zoom helpers

    /// Scale factor to maximally fit the image in the canvas without cropping.
    /// For a tall image: top/bottom touch the canvas edges.
    /// For a wide image: left/right touch the canvas edges.
    /// Always fills as much space as possible — upscales small images too.
    private var fitZoom: CGFloat {
        guard let img = document.sourceImage,
              img.size.width > 0, img.size.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return 1.0 }
        // The image view is sized to min(img.size, canvas*0.92) before scaleEffect.
        // We need to compute what scaleEffect value makes it fill the canvas.
        let frameW = min(img.size.width, canvasSize.width  * 0.92)
        let frameH = min(img.size.height, canvasSize.height * 0.92)
        // Available space with small inset so it doesn't clip the very edge
        let availW = canvasSize.width  * 0.96
        let availH = canvasSize.height * 0.96
        let scaleW = availW / frameW
        let scaleH = availH / frameH
        return min(scaleW, scaleH) // take the smaller scale so nothing is cropped
    }

    // MARK: - Export

    private func saveOptimizedImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = document.suggestedFilename
        panel.prompt = "Export"
        panel.message = "Export optimised PNG"
        if let dir = document.sourceDirectoryURL {
            panel.directoryURL = dir
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Prefer quantized data; fall back to source
            let data = document.quantizedData ?? document.sourceData
            guard let data else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Drop a PNG here or click to open")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            openFilePicker()
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await document.load(url: url) }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Zoom controls — compact icon buttons: − + 1 fit
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { userZoom = max(0.05, userZoom / 1.5) }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { userZoom = min(8.0, userZoom * 1.5) }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")

                Button {
                    zoomableResetID += 1
                    withAnimation(.easeInOut(duration: 0.15)) { userZoom = 1.0 }
                } label: {
                    Image(systemName: "1.magnifyingglass")
                }
                .help("Actual size — show image at its native pixel dimensions")

                Button {
                    zoomableResetID += 1
                    withAnimation(.easeInOut(duration: 0.15)) { userZoom = fitZoom }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Fit to window")
            }
            .buttonStyle(.borderless)
            .disabled(document.sourceImage == nil)

            Spacer()

            // Show spinner while processing, file size pill when done
            if document.isProcessing {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Optimizing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.fill.secondary, in: Capsule())
            } else if document.sourceFileSize > 0, document.quantizedFileSize > 0 {
                fileSizePill
            }

            // Zebra diff toggle
            Toggle(isOn: Binding(
                get: { document.showZebra },
                set: { document.showZebra = $0 }
            )) {
                Image(systemName: "camera.metering.spot")
            }
            .toggleStyle(.button)
            .help("Show zebra diff — highlights areas that changed (⌘D)")
            .keyboardShortcut("d", modifiers: .command)
            .disabled(document.quantizedImage == nil)

            // Show original toggle
            Toggle(isOn: $document.showOriginal) {
                Label("Original", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Toggle original / optimized (⌘T)")
            .keyboardShortcut("t", modifiers: .command)
            .disabled(document.sourceImage == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thickMaterial)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - File size pill

    private var fileSizePill: some View {
        HStack(spacing: 5) {
            Text(document.formatBytes(document.sourceFileSize))
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(document.formatBytes(document.quantizedFileSize))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            if document.compressionRatio < 1.0 {
                Text("−\(String(format: "%.0f", (1.0 - document.compressionRatio) * 100))%")
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green, in: Capsule())
            } else if document.compressionRatio > 1.0 {
                Text("+\(String(format: "%.0f", (document.compressionRatio - 1.0) * 100))%")
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.secondary, in: Capsule())
    }
}

// MARK: - BackgroundCanvasView
// Pure SwiftUI Canvas — draws checkerboard, solid color, or tiled pattern.
// This view is NOT inside the zoomable modifier — it stays fixed.

struct BackgroundCanvasView: View {
    let style: Lossly.BackgroundStyle

    var body: some View {
        switch style {
        case .checkerboard:
            Canvas { ctx, size in
                let cell: CGFloat = 8
                let cols = Int(ceil(size.width  / cell)) + 1
                let rows = Int(ceil(size.height / cell)) + 1
                let light = Color(white: 0.82)
                let dark  = Color(white: 0.65)
                for row in 0..<rows {
                    for col in 0..<cols {
                        let color = (row + col) % 2 == 0 ? light : dark
                        let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                          width: cell, height: cell)
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }
        case .color(let c):
            Rectangle().fill(Color(c))
        case .pattern(_, let img):
            TiledPatternView(image: img)
        }
    }
}

// MARK: - TiledPatternView

struct TiledPatternView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSView {
        let v = TiledNSView()
        v.tileImage = image
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v as? TiledNSView)?.tileImage = image
    }

    private class TiledNSView: NSView {
        var tileImage: NSImage? { didSet { needsDisplay = true } }
        override func draw(_ rect: NSRect) {
            guard let img = tileImage,
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = NSGraphicsContext.current?.cgContext else { return }
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            ctx.saveGState(); ctx.clip(to: rect)
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX { ctx.draw(cg, in: CGRect(x: x, y: y, width: w, height: h)); x += w }
                y += h
            }
            ctx.restoreGState()
        }
    }
}
