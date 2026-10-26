import AppKit

/// The Dock tile during a batch (DESIGN_DIRECTION 3.3, 4.11): the real icon
/// with a determinate bar 10 pt tall; track black at 70 %, fill white,
/// radius 5. No badge text; removed when the batch ends.
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

    /// The bar on a tile of `size`, in points from the bottom-left. 3.3's
    /// "14 pt from the tile's edge" put it on the icon's transparent margin
    /// (about 12.5 pt on a 128 pt tile) with its ends past the rounded
    /// corners (review, 26 Oct); 24 pt from the sides and 22 pt from the
    /// bottom keep it on the icon's body.
    static func barRect(in size: CGSize) -> CGRect {
        let scale = size.width / 128
        return CGRect(x: 24 * scale, y: 22 * scale, width: size.width - 48 * scale, height: 10 * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let track = Self.barRect(in: bounds.size)
        let height = track.height
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var fill = track
        fill.size.width = max(height, track.width * fraction)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
