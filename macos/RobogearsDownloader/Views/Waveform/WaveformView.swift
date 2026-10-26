import SwiftUI

/// The signature element (DESIGN_DIRECTION 3.4): 200 square bars, played in
/// full ink, unplayed at 22 %. Hover is light only: bars within ten of the
/// pointer brighten toward 60 % and a 1 pt cursor line follows the pointer;
/// no bar changes height. Press seeks (or starts this row at that point),
/// drag skims while the audio keeps playing, seeking never pauses.
struct WaveformView: View {
    let model: AppModel
    let rowID: UUID
    let peaks: [Float]?
    var emphasized = false
    /// The snapshot harness pins a pointer position.
    var hoverOverride: Double?

    @State private var hoverFraction: Double?
    @State private var width: CGFloat = 0
    @State private var isScrubbing = false
    @FocusState private var isFocused: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.displayPreferences) private var prefs

    private var isCurrent: Bool { model.nowPlayingID == rowID && model.previewLoadingID != rowID }

    var body: some View {
        _ = model.previewPositionToken
        return Group {
            if isCurrent && model.isPreviewPlaying && model.previewProgressOverride == nil {
                // Only the playing row ticks, at the display rate; nothing else repaints.
                TimelineView(.animation) { _ in bars(progress: model.previewProgress) }
            } else {
                bars(progress: isCurrent ? model.previewProgress : 0)
            }
        }
        .frame(height: Metrics.waveformHeight)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                hoverFraction = width > 0 ? Double(min(max(0, point.x / width), 1)) : nil
            case .ended:
                if !isScrubbing { hoverFraction = nil }
            }
        }
        .gesture(scrub)
        .focusable(peaks != nil || isCurrent, interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled(false)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end, .space], phases: [.down, .repeat]) { press in
            handleKey(press)
        }
        .accessibilityElement()
        .accessibilityLabel("Preview position")
        .accessibilityValue(model.previewPositionDescription(for: rowID))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seekBy(5)
            case .decrement: seekBy(-5)
            @unknown default: break
            }
        }
    }

    // MARK: Drawing

    private func bars(progress: Double) -> some View {
        let hover = hoverOverride ?? hoverFraction
        let ink = emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : Palette.ink
        let unplayedAlpha = prefs.increasedContrast ? 0.45 : 0.22
        let hoverMaxAlpha = prefs.increasedContrast ? 0.80 : 0.60
        let cursorAlpha = prefs.increasedContrast ? 0.80 : 0.55
        let scale = max(1, displayScale)
        let peaks = self.peaks

        return Canvas { context, size in
            guard let peaks else { return }
            for bar in WaveformBars.layout(peaks: peaks, size: size, scale: scale, progress: progress, hover: hover,
                                           unplayedAlpha: unplayedAlpha, hoverMaxAlpha: hoverMaxAlpha) {
                context.fill(Path(bar.rect), with: .color(ink.opacity(bar.alpha)))
            }
            if let hover {
                let x = (CGFloat(hover) * size.width).rounded(.down) + 0.5
                let line = CGRect(x: x - 0.5, y: 2, width: 1, height: size.height - 4)
                context.fill(Path(line), with: .color(ink.opacity(cursorAlpha)))
            }
        }
    }

    // MARK: Pointer

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard width > 0 else { return }
                let fraction = Double(min(max(0, value.location.x / width), 1))
                hoverFraction = fraction
                if !isScrubbing {
                    isScrubbing = true
                    model.seekPreview(rowID, toFraction: fraction)
                } else if isCurrent {
                    // Skim: seek while the audio keeps playing.
                    model.player.seek(toFraction: fraction)
                }
            }
            .onEnded { value in
                isScrubbing = false
                let inside = value.location.x >= 0 && value.location.x <= width
                    && value.location.y >= 0 && value.location.y <= Metrics.waveformHeight
                if !inside { hoverFraction = nil }
            }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: seekBy(press.modifiers.contains(.shift) ? -30 : -5)
        case .rightArrow: seekBy(press.modifiers.contains(.shift) ? 30 : 5)
        case .home: model.seekPreview(rowID, toFraction: 0)
        case .end: model.seekPreview(rowID, toFraction: 0.999)
        case .space:
            guard press.phase == .down else { return .handled }
            model.togglePreview(rowID)
        default: return .ignored
        }
        return .handled
    }

    private func seekBy(_ seconds: Double) {
        if isCurrent {
            model.seekPreview(rowID, bySeconds: seconds)
        } else {
            model.seekPreview(rowID, toFraction: 0)
        }
    }
}

/// Where the bars go and how strong each is (DESIGN_DIRECTION 3.4), apart
/// from the drawing so the rule can be checked without drawing.
enum WaveformBars {
    struct Bar: Equatable {
        var rect: CGRect
        var alpha: Double
    }

    /// From 200 pt up: one bar per peak, `max(1, pitch − 1)` wide, each x
    /// rounded to the backing pixel. Narrower, a bar would be under 1 pt and
    /// neighbours would overlap, stacking their alpha until an unplayed
    /// waveform looked played (review, 26 Oct). There each 1 pt column draws
    /// the loudest of its peaks, so bars touch and never overlap; the played
    /// test and the hover falloff use the column's place in the track.
    static func layout(peaks: [Float], size: CGSize, scale: CGFloat, progress: Double, hover: Double?,
                       unplayedAlpha: Double, hoverMaxAlpha: Double) -> [Bar] {
        guard !peaks.isEmpty, size.width >= 1 else { return [] }
        let n = peaks.count
        let columns = size.width / CGFloat(n) < 1 ? max(1, Int(size.width)) : n
        let pitch = size.width / CGFloat(columns)
        let barWidth = max(1, pitch - 1)
        let hoverBar = hover.map { $0 * Double(n) - 0.5 }
        var bars: [Bar] = []
        bars.reserveCapacity(columns)
        for c in 0..<columns {
            let first = c * n / columns
            let last = max(first + 1, (c + 1) * n / columns)
            let peak = peaks[first..<min(n, last)].max() ?? 0
            let x = (CGFloat(c) * pitch * scale).rounded() / scale
            let h = max(1, CGFloat(peak) * Metrics.waveformHeight * 0.78)
            let rect = CGRect(x: x, y: ((size.height - h) / 2 * scale).rounded() / scale, width: barWidth, height: h)
            // The bar's centre as a fraction of the track; with one bar per
            // peak this is (i + 0.5) / 200, and `position × 200 − 0.5` is i.
            let position = (Double(c) + 0.5) / Double(columns)
            let played = position <= progress
            var alpha = played ? 1 : unplayedAlpha
            if !played, let hoverBar {
                let d = abs(position * Double(n) - 0.5 - hoverBar)
                if d < 10 { alpha = unplayedAlpha + (hoverMaxAlpha - unplayedAlpha) * (1 - d / 10) }
            }
            bars.append(Bar(rect: rect, alpha: alpha))
        }
        return bars
    }
}
