import AppKit

/// Custom Dock-tile content view that draws the app icon with a slim
/// progress bar overlaid near the bottom while downloads are running.
/// Same idea as Adobe Media Encoder / Safari / App Store while installing.
@MainActor
final class DockProgressView: NSView {

    static let shared = DockProgressView(
        frame: NSRect(x: 0, y: 0, width: 128, height: 128)
    )

    /// 0.0 … 1.0. When outside that range (or exactly 0/1) the bar is not
    /// drawn and the Dock tile looks like the plain app icon.
    var progress: Double = 0 {
        didSet {
            guard oldValue != progress else { return }
            needsDisplay = true
            NSApp.dockTile.display()
        }
    }

    /// Forces a redraw without changing progress — called by
    /// IconController when it swaps the light/dark icon variant.
    func refresh() {
        needsDisplay = true
        NSApp.dockTile.display()
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 1. Draw the current app icon as the background.
        if let icon = NSApp.applicationIconImage {
            icon.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        // 2. Overlay a progress bar, but only while a download is in
        //    progress (strictly between 0 and 1).
        guard progress > 0, progress < 1 else { return }

        let barHeight: CGFloat = 10
        let sideInset: CGFloat = 14
        let bottomInset: CGFloat = 14
        let corner: CGFloat = barHeight / 2

        let trackRect = NSRect(
            x: sideInset,
            y: bottomInset,
            width: bounds.width - sideInset * 2,
            height: barHeight
        )

        // Track (dark, semi-transparent)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: corner,
            yRadius: corner
        ).fill()

        // Fill
        let clamped = max(0.0, min(1.0, progress))
        let fillWidth = max(barHeight, trackRect.width * CGFloat(clamped))
        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: fillWidth,
            height: trackRect.height
        )
        BrandColor.red.setFill()
        NSBezierPath(
            roundedRect: fillRect,
            xRadius: corner,
            yRadius: corner
        ).fill()

        // Thin white outline so it pops on any icon background
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(
            roundedRect: trackRect,
            xRadius: corner,
            yRadius: corner
        )
        outline.lineWidth = 1
        outline.stroke()
    }
}
