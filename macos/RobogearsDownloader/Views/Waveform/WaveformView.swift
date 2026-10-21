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
            guard let peaks, !peaks.isEmpty, size.width >= 1 else { return }
            let n = peaks.count
            let pitch = size.width / CGFloat(n)
            let barWidth = max(1, pitch - 1)
            let hoverBar = hover.map { $0 * Double(n) - 0.5 }
            for i in 0..<n {
                let x = (CGFloat(i) * pitch * scale).rounded() / scale
                let h = max(1, CGFloat(peaks[i]) * Metrics.waveformHeight * 0.78)
                let rect = CGRect(x: x, y: ((size.height - h) / 2 * scale).rounded() / scale, width: barWidth, height: h)
                let played = (Double(i) + 0.5) / Double(n) <= progress
                var alpha = played ? 1 : unplayedAlpha
                if !played, let hoverBar {
                    let d = abs(Double(i) - hoverBar)
                    if d < 10 { alpha = unplayedAlpha + (hoverMaxAlpha - unplayedAlpha) * (1 - d / 10) }
                }
                context.fill(Path(rect), with: .color(ink.opacity(alpha)))
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
