import RobogearsCore
import SwiftUI

/// The snapshot harness pins a hover on one row (pointer at a fraction of
/// its waveform), since an off-screen window has no pointer.
struct SnapshotHover: Equatable {
    var rowID: UUID
    var fraction: Double
}

extension EnvironmentValues {
    @Entry var snapshotHover: SnapshotHover?
}

/// One queue row (DESIGN_DIRECTION 4.4): play · title · waveform · artist ·
/// badge · status · action · remove, 28 pt, growing to 44 pt with a second line.
struct TrackRow: View {
    let row: QueueRow
    let model: AppModel

    @State private var isHovering = false
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.snapshotHover) private var snapshotHover

    private var hovering: Bool { isHovering || snapshotHover?.rowID == row.id }
    /// Selected in a focused list: text and bars take the selection text colour.
    private var emphasized: Bool { prominence == .increased }
    private var ink: Color { emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : Palette.ink }
    private var secondary: Color { emphasized ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : Palette.inkSecondary }
    private var tertiary: Color { emphasized ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.75) : Palette.inkTertiary }

    var body: some View {
        let facts = model.facts(row)
        let p = RowPresentation.make(facts)
        let isSelected = model.selection.contains(row.id)
        let dim = p.isLeftOut && !prefs.increasedContrast ? 0.5 : 1

        VStack(alignment: .leading, spacing: 0) {
            RowLineLayout {
                playSlot(p).rowPart(.play)
                title(p).opacity(dim).rowPart(.title)
                waveform(p).opacity(dim).rowPart(.waveform)
                artistLine.opacity(dim).rowPart(.artist)
                if let badge = p.badge { QualityBadge(text: badge, color: tertiary).rowPart(.badge) }
                if let status = p.status { StatusLabel(status: status, emphasized: emphasized).rowPart(.status) }
                if let action = p.action { actionButton(action).rowPart(.action) }
                removeButton(visible: hovering || isSelected).rowPart(.remove)
            }
            .frame(height: Metrics.rowHeight)
            if let line = p.secondLine {
                Text(line)
                    .font(Typography.secondLine)
                    .foregroundStyle(p.status?.tone == .failed && !emphasized ? Palette.inkTertiary : tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, Metrics.playHit + Metrics.gapAfterPlay)
                    .frame(height: Metrics.rowHeightTwoLines - Metrics.rowHeight, alignment: .top)
                    .help(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if p.showsProgressLine { ProgressLine(percent: row.percent, ink: ink) }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Motion.ease(Motion.hover, reduceMotion: prefs.reduceMotion), value: hovering)
        .listRowBackground(hovering && !isSelected ? Palette.surface : Color.clear)
        .onAppear { model.rowAppeared(row.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RowPresentation.accessibilityLabel(facts, p))
        .accessibilityActions { accessibilityActions(p) }
    }

    // MARK: Parts

    @ViewBuilder
    private func playSlot(_ p: RowPresentation) -> some View {
        if p.canPreview {
            PlayButton(model: model, rowID: row.id, dimmed: p.previewDimmed, emphasized: emphasized)
        } else {
            Color.clear.frame(width: Metrics.playHit, height: Metrics.playHit)
        }
    }

    private func title(_ p: RowPresentation) -> some View {
        HStack(spacing: 6) {
            let name = Text(verbatim: row.item.title).font(Typography.rowTitle).foregroundStyle(ink)
            let edition = Text(verbatim: row.item.version.map { " — \($0)" } ?? "").font(Typography.edition).foregroundStyle(secondary)
            Text("\(name)\(edition)")
                .strikethrough(p.isLeftOut, color: secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if row.item.explicit {
                ExplicitMark(ink: ink)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func waveform(_ p: RowPresentation) -> some View {
        if p.canPreview {
            WaveformView(model: model, rowID: row.id, peaks: row.preview.peaks, emphasized: emphasized,
                         hoverOverride: snapshotHover?.rowID == row.id ? snapshotHover?.fraction : nil)
        } else {
            // Rows that can't preview keep the slot so columns stay aligned.
            Color.clear.frame(height: Metrics.waveformHeight).accessibilityHidden(true)
        }
    }

    private var artistLine: some View {
        let parts = [row.item.artist.isEmpty ? nil : row.item.artist, Formatting.duration(row.item.durationSeconds)].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .font(Typography.artist)
            .foregroundStyle(secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actionButton(_ command: RowCommand) -> some View {
        if command == .include {
            // "+ Add" is the row's one prominent control (4.4), in the ink.
            Button { model.perform(command, on: [row.id]) } label: {
                Text(command.buttonTitle).inkProminentLabel()
            }
            .inkProminent()
            .controlSize(.small)
            .help("Add to the download")
            .accessibilityHidden(true)
        } else {
            Button(command.buttonTitle) { model.perform(command, on: [row.id]) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(command.title)
                .accessibilityHidden(true)
        }
    }

    private func removeButton(visible: Bool) -> some View {
        RemoveButton(emphasized: emphasized) { model.remove([row.id]) }
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .help(row.inBatch ? "Remove from Queue and from this batch" : "Remove from Queue")
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func accessibilityActions(_ p: RowPresentation) -> some View {
        if p.canPreview {
            Button(model.nowPlayingID == row.id && model.isPreviewPlaying ? "Pause Preview" : "Play Preview") {
                model.togglePreview(row.id)
            }
        }
        if let action = p.action, action != .remove {
            Button(action == .include ? "Add to Download" : action.title) { model.perform(action, on: [row.id]) }
        }
        ForEach(p.commands.filter { $0 != p.action && $0 != .remove && $0 != .copyTitleAndArtist }, id: \.self) { command in
            Button(command.title) { model.perform(command, on: [row.id]) }
        }
        Button("Remove from Queue") { model.remove([row.id]) }
    }
}

/// The 2 pt progress line along a downloading row's bottom edge: Ink on Surface2.
private struct ProgressLine: View {
    let percent: Int
    let ink: Color
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.surface2)
                Rectangle().fill(ink).frame(width: geo.size.width * CGFloat(min(100, max(0, percent))) / 100)
            }
        }
        .frame(height: Metrics.progressLine)
        .animation(Motion.linear(Motion.progress, reduceMotion: prefs.reduceMotion), value: percent)
        .accessibilityHidden(true)
    }
}

/// "E": 9 pt bold in a 12×12 pt, 2 pt-radius ink square.
struct ExplicitMark: View {
    var ink: Color = Palette.ink

    var body: some View {
        Text("E")
            .font(Typography.explicitMark)
            .foregroundStyle(Palette.canvas)
            .frame(width: Metrics.explicitMark, height: Metrics.explicitMark)
            .background(ink, in: RoundedRectangle(cornerRadius: 2))
            .accessibilityLabel("Explicit")
    }
}

/// "Hi-Res" / "AAC": caption2 medium in a 1 pt hairline capsule.
struct QualityBadge: View {
    let text: String
    var color: Color = Palette.inkTertiary
    /// The capsule's stroke: Hairline on the canvas, the system separator in sheets.
    var stroke: Color = Palette.hairline

    var body: some View {
        Text(text)
            .font(Typography.badge)
            .foregroundStyle(color)
            .padding(.vertical, 1)
            .padding(.horizontal, 5)
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .fixedSize()
    }
}

/// Symbol (small) + words, in the status colour; never colour alone.
struct StatusLabel: View {
    let status: RowPresentation.Status
    var emphasized = false
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        let color = emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : status.tone.color
        HStack(spacing: 4) {
            if status.showsSpinner {
                ProgressView().controlSize(.mini)
            } else if let symbol = status.symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .symbolRenderingMode(.monochrome)
                    .contentTransition(prefs.reduceMotion ? .identity : .symbolEffect(.replace))
            }
            Text(status.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(prefs.reduceMotion ? .identity : .numericText())
        }
        .font(Typography.status)
        .foregroundStyle(color)
        .help(status.text)
        .animation(Motion.ease(Motion.symbol, reduceMotion: prefs.reduceMotion), value: status.text)
        .accessibilityHidden(true)
    }
}

/// The 20 pt play circle in a 24 pt hit area (4.4 part 1).
struct PlayButton: View {
    let model: AppModel
    let rowID: UUID
    var dimmed = false
    var emphasized = false
    @State private var hovering = false
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        let isCurrent = model.nowPlayingID == rowID
        let isLoading = model.previewLoadingID == rowID
        let isPlaying = isCurrent && model.isPreviewPlaying && !isLoading
        let ink = emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : Palette.ink
        let rest = emphasized ? ink.opacity(0.75) : Palette.inkTertiary
        let ring = hovering || isPlaying ? ink : (emphasized ? ink.opacity(0.5) : Palette.hairline)

        Button {
            model.togglePreview(rowID)
        } label: {
            ZStack {
                if isPlaying {
                    Circle().fill(ink)
                } else {
                    Circle().strokeBorder(ring, lineWidth: 1)
                }
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: Metrics.playGlyph, weight: .regular))
                        .foregroundStyle(isPlaying ? (emphasized ? Palette.ink : Palette.canvas) : (hovering ? ink : rest))
                        .offset(x: isPlaying ? 0 : 0.5)
                }
            }
            .frame(width: Metrics.playVisible, height: Metrics.playVisible)
            .frame(width: Metrics.playHit, height: Metrics.playHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.4 : 1)
        .onHover { hovering = $0 }
        .animation(Motion.ease(Motion.hover, reduceMotion: prefs.reduceMotion), value: hovering)
        .help(isPlaying ? "Pause preview" : "Play preview")
        .accessibilityLabel(isLoading ? "Loading preview" : (isPlaying ? "Pause preview" : "Play preview"))
    }
}

/// The 11 pt × in a 20 pt hit area.
struct RemoveButton: View {
    var emphasized = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        let ink = emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : Palette.ink
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: Metrics.removeGlyph, weight: .medium))
                .foregroundStyle(hovering ? ink : (emphasized ? ink.opacity(0.75) : Palette.inkTertiary))
                .frame(width: Metrics.removeHit, height: Metrics.removeHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.ease(Motion.hover, reduceMotion: prefs.reduceMotion), value: hovering)
        .accessibilityLabel("Remove from Queue")
    }
}
