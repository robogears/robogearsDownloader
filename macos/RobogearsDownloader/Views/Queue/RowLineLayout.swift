import SwiftUI

/// The parts of a row's first line, tagged so the layout knows the rule each follows.
enum RowPart: Equatable {
    case play, title, waveform, artist, badge, status, action, remove
}

private struct RowPartKey: LayoutValueKey {
    static let defaultValue: RowPart = .status
}

extension View {
    func rowPart(_ part: RowPart) -> some View { layoutValue(key: RowPartKey.self, value: part) }
}

/// The width rule of DESIGN_DIRECTION 3.4: the title gets its full width
/// first; artist and status next (artist 80…220 pt, then tail truncation);
/// the waveform takes what's left and shrinks to nothing. Only once the
/// waveform is at 0 and the artist slot at 80 pt does the title truncate
/// (in the middle, set on the Text itself).
struct RowLineLayout: Layout {
    var height: CGFloat = Metrics.rowHeight

    private func gapAfter(_ part: RowPart, next: RowPart?) -> CGFloat {
        guard let next else { return 0 }
        switch (part, next) {
        case (.play, _): return Metrics.gapAfterPlay
        case (.title, .waveform), (.waveform, _): return Metrics.gapAroundWaveform
        case (.artist, _): return Metrics.gapArtistToBadge
        case (.badge, _): return Metrics.gapArtistToBadge
        case (.status, .action): return Metrics.gapStatusToAction
        case (_, .remove): return Metrics.gapBeforeRemove
        default: return Metrics.gapStatusToAction
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 600, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = subviews.map { $0[RowPartKey.self] }
        let unbounded = ProposedViewSize(width: nil, height: height)
        var widths = subviews.map { $0.sizeThatFits(unbounded).width }

        var gaps: CGFloat = 0
        for i in parts.indices { gaps += gapAfter(parts[i], next: i + 1 < parts.count ? parts[i + 1] : nil) }

        // Natural widths, with the artist clamped to 220 and the status to 200.
        for i in parts.indices {
            switch parts[i] {
            case .artist: widths[i] = min(widths[i], Metrics.artistMaxWidth)
            case .status: widths[i] = min(widths[i], Metrics.statusMaxWidth)
            case .waveform: widths[i] = 0
            default: break
            }
        }
        let fixedTotal = widths.reduce(0, +) + gaps
        var spare = bounds.width - fixedTotal

        if let w = parts.firstIndex(of: .waveform) {
            widths[w] = max(0, spare)
        }
        if spare < 0, let a = parts.firstIndex(of: .artist) {
            // Waveform is gone: the artist gives up width down to 80 pt.
            let floor = min(widths[a], Metrics.artistMinWidth)
            let give = min(widths[a] - floor, -spare)
            widths[a] -= give
            spare += give
        }
        if spare < 0, let t = parts.firstIndex(of: .title) {
            // Only now does the title truncate.
            widths[t] = max(0, widths[t] + spare)
        }

        var x = bounds.minX
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(ProposedViewSize(width: widths[i], height: height))
            let place = parts[i] == .waveform ? CGSize(width: widths[i], height: Metrics.waveformHeight) : size
            subviews[i].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: widths[i], height: place.height))
            x += widths[i] + gapAfter(parts[i], next: i + 1 < parts.count ? parts[i + 1] : nil)
        }
    }
}
