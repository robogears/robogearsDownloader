import SwiftUI

/// The vinyl-with-arrow mark as a template shape (DESIGN_DIRECTION 2, Q3):
/// the record is ink, the label is a hole showing the canvas, the arrow on
/// the label is ink again. Drawn from the Electron topbar glyph (a 24-unit
/// box: record radius 10, label radius 5, arrow polygon), so it inverts with
/// the appearance instead of being a fixed white picture.
struct BrandGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let unit = side / 24
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }

        var path = Path()
        path.addEllipse(in: CGRect(origin: pt(2, 2), size: CGSize(width: 20 * unit, height: 20 * unit)))
        path.addEllipse(in: CGRect(origin: pt(7, 7), size: CGSize(width: 10 * unit, height: 10 * unit)))
        // The download arrow, inside the label hole: even-odd filling turns it back to ink.
        path.move(to: pt(10.5, 7.6))
        path.addLine(to: pt(13.5, 7.6))
        path.addLine(to: pt(13.5, 10.4))
        path.addLine(to: pt(15.3, 10.4))
        path.addLine(to: pt(12, 14.6))
        path.addLine(to: pt(8.7, 10.4))
        path.addLine(to: pt(10.5, 10.4))
        path.closeSubpath()
        return path
    }
}

/// The glyph filled with the even-odd rule.
struct BrandGlyphView: View {
    var color: Color = Palette.inkTertiary

    var body: some View {
        BrandGlyph()
            .fill(color, style: FillStyle(eoFill: true, antialiased: true))
            .accessibilityHidden(true)
    }
}
