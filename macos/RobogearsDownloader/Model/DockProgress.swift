import AppKit

/// The Dock tile during a batch (DESIGN_DIRECTION 3.3, 4.11): the real icon
/// with a determinate bar 10 pt tall, inset 14 pt from the sides and bottom
/// of the 128 pt tile; track black at 70 %, fill white, radius 5. No badge
/// text; removed when the batch ends.
@MainActor
final class DockProgress {
    private var view: DockProgressView?

    func show(fraction: Double) {
        let tile = NSApp.dockTile
        if view == nil {
            let v = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            view = v
            tile.contentView = v
        }
        view?.fraction = min(1, max(0, fraction))
        tile.display()
    }

    func clear() {
        guard view != nil else { return }
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        view = nil
    }
}

final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let scale = bounds.width / 128
        let inset = 14 * scale
        let height = 10 * scale
        let radius = 5 * scale
        let track = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: height)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var fill = track
        fill.size.width = max(height, track.width * fraction)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
