import AppKit

// MARK: - Architecture
//
// ┌─ ScrollableImageView (NSView container) ──────────────────────────┐
// │  ┌─ BackgroundView (fills entire bounds, fixed, never zooms) ───┐ │
// │  │  draws checkerboard / solid color / tiled pattern            │ │
// │  └───────────────────────────────────────────────────────────── ┘ │
// │  ┌─ NSScrollView (on top, transparent background) ──────────────┐ │
// │  │  allowsMagnification = true                                  │ │
// │  │  ┌─ ImageView (NSImageView, the documentView) ─────────────┐ │ │
// │  │  │  draws just the image, centered via insets              │ │ │
// │  │  └────────────────────────────────────────────────────────  ┘ │ │
// │  └──────────────────────────────────────────────────────────────  ┘ │
// └─────────────────────────────────────────────────────────────────────┘
//
// Result:
// - Background is FIXED — never zooms or pans
// - NSScrollView handles pinch-to-zoom natively (fast, no lag)
// - NSScrollView handles two-finger pan natively
// - Image is centered in the scroll view

// MARK: - BackgroundView

final class BackgroundView: NSView {

    var style: Lossly.BackgroundStyle = .checkerboard {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch style {
        case .checkerboard:      drawCheckerboard(ctx: ctx, in: bounds)
        case .color(let c):      ctx.setFillColor(c.cgColor); ctx.fill(bounds)
        case .pattern(_, let i): drawTiled(ctx: ctx, image: i, in: bounds)
        }
    }

    private func drawCheckerboard(ctx: CGContext, in rect: CGRect) {
        let cell: CGFloat = 8
        let light = NSColor(white: 0.82, alpha: 1).cgColor
        let dark  = NSColor(white: 0.65, alpha: 1).cgColor
        let cols = Int(ceil(rect.width  / cell)) + 1
        let rows = Int(ceil(rect.height / cell)) + 1
        for row in 0..<rows {
            for col in 0..<cols {
                ctx.setFillColor((row + col) % 2 == 0 ? light : dark)
                ctx.fill(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                width: cell, height: cell))
            }
        }
    }

    private func drawTiled(ctx: CGContext, image: NSImage, in rect: CGRect) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            drawCheckerboard(ctx: ctx, in: rect); return
        }
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

// MARK: - ScrollableImageView (the outer container)

final class ScrollableImageView: NSView {

    // MARK: Public state

    var image: NSImage? {
        didSet {
            imageView.image = image
            updateImageViewSize()
            if image != nil {
                DispatchQueue.main.async { [weak self] in self?.fitImageToView(animated: false) }
            }
        }
    }

    var originalImage: NSImage?

    var showingOriginal: Bool = false {
        didSet { imageView.image = showingOriginal ? (originalImage ?? image) : image }
    }

    var background: Lossly.BackgroundStyle = .checkerboard {
        didSet { backgroundView.style = background }
    }

    var onZoomChanged: ((Double) -> Void)?

    // MARK: Private views

    private let backgroundView = BackgroundView()
    private let scrollView     = NSScrollView()
    private let imageView      = NSImageView()

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        // 1. Background — pinned to edges, never zooms
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 2. Scroll view — transparent, on top of background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor        = .clear
        scrollView.drawsBackground        = false
        scrollView.hasVerticalScroller    = true
        scrollView.hasHorizontalScroller  = true
        scrollView.autohidesScrollers     = true
        scrollView.allowsMagnification    = true
        scrollView.minMagnification       = 0.02
        scrollView.maxMagnification       = 32.0
        scrollView.usesPredominantAxisScrolling = false

        let clip = NSClipView()
        clip.backgroundColor = .clear
        clip.drawsBackground = false
        scrollView.contentView = clip

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 3. Image view — the document view
        imageView.imageScaling    = .scaleNone
        imageView.imageAlignment  = .alignCenter
        imageView.wantsLayer      = true
        imageView.layer?.shadowColor   = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = 0.25
        imageView.layer?.shadowRadius  = 8
        imageView.layer?.shadowOffset  = CGSize(width: 0, height: -2)
        scrollView.documentView = imageView

        // 4. Listen for magnification changes (live + end)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(magnificationChanged),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(magnificationChanged),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView
        )
        // Also observe bounds change to keep centering during live magnify
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func magnificationChanged() {
        updateScrollInsets()
        onZoomChanged?(scrollView.magnification)
    }

    @objc private func boundsChanged() {
        updateScrollInsets()
    }

    // MARK: - Image sizing

    private func updateImageViewSize() {
        guard let img = image else {
            imageView.setFrameSize(NSSize(width: 100, height: 100))
            return
        }
        imageView.setFrameSize(img.size)
    }

    // MARK: - Fit to view

    func fitImageToView(animated: Bool = false) {
        guard let img = image else { return }
        let viewSize = scrollView.contentView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let scaleX = viewSize.width  / img.size.width
        let scaleY = viewSize.height / img.size.height
        let scale  = min(scaleX, scaleY) * 0.92
        let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, scale))

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.scrollView.animator().magnification = clamped
            }
        } else {
            scrollView.magnification = clamped
        }
        centerDocument()
        onZoomChanged?(clamped)
    }

    func centerDocument() {
        guard let doc = scrollView.documentView else { return }
        let docFrame   = doc.frame
        let clipBounds = scrollView.contentView.bounds
        let scaledW    = docFrame.width  * scrollView.magnification
        let scaledH    = docFrame.height * scrollView.magnification
        let x = max(0, (scaledW - clipBounds.width)  / 2)
        let y = max(0, (scaledH - clipBounds.height) / 2)
        scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Zoom actions (animated)

    func zoomIn() {
        animateTo(scrollView.magnification * 1.5)
    }

    func zoomOut() {
        animateTo(scrollView.magnification / 1.5)
    }

    func zoomActualSize() {
        animateTo(1.0)
    }

    private func animateTo(_ zoom: Double) {
        let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, zoom))
        let center  = CGPoint(x: scrollView.contentView.bounds.midX,
                               y: scrollView.contentView.bounds.midY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.scrollView.animator().setMagnification(clamped, centeredAt: center)
        }
        onZoomChanged?(clamped)
    }

    // MARK: - Layout

    private var isUpdatingInsets = false

    override func layout() {
        super.layout()
        updateScrollInsets()
    }

    private func updateScrollInsets() {
        guard !isUpdatingInsets, let img = image else { return }
        let visible = scrollView.contentView.bounds.size
        guard visible.width > 0, visible.height > 0 else { return }
        let scaledW = img.size.width  * scrollView.magnification
        let scaledH = img.size.height * scrollView.magnification
        let hInset  = max(0, (visible.width  - scaledW) / 2)
        let vInset  = max(0, (visible.height - scaledH) / 2)
        let cur = scrollView.contentInsets
        guard abs(cur.top - vInset) > 0.5 || abs(cur.left - hInset) > 0.5 else { return }
        isUpdatingInsets = true
        scrollView.contentInsets = NSEdgeInsets(top: vInset, left: hInset,
                                                 bottom: vInset, right: hInset)
        isUpdatingInsets = false
    }

    // MARK: - Mouse drag panning + hand cursor

    private var dragStart: NSPoint = .zero
    private var dragScrollOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragScrollOrigin = scrollView.contentView.bounds.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        let dx = current.x - dragStart.x
        let dy = current.y - dragStart.y
        let newOrigin = NSPoint(
            x: dragScrollOrigin.x - dx,
            y: dragScrollOrigin.y - dy
        )
        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override var acceptsFirstResponder: Bool { true }
}
