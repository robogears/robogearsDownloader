import RobogearsCore
import SwiftUI

/// Everything above the activity panel: add area, header, batch slot and the
/// list, or the empty state when there are no rows (DESIGN_DIRECTION 4.3).
struct QueueArea: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                if model.summary != nil {
                    BatchSlot(model: model)
                        .padding(.horizontal, Metrics.contentInset)
                        .padding(.top, Metrics.regionGap)
                }
                EmptyStateView(model: model)
            } else {
                AddArea(model: model)
                    .padding(.horizontal, Metrics.contentInset)
                    .padding(.top, 6)
                QueueHeader(model: model)
                    .padding(.horizontal, Metrics.contentInset)
                BatchSlot(model: model)
                    .padding(.horizontal, Metrics.contentInset)
                QueueList(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The list of rows (4.3 QueueList): native multi-select, context menus,
/// ⌫ removes, Space previews only while the list has focus, drag to reorder.
struct QueueList: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.rows) { row in
                TrackRow(row: row, model: model)
                    .listRowInsets(EdgeInsets(top: Metrics.rowInsetVertical, leading: Metrics.rowInsetHorizontal,
                                              bottom: Metrics.rowInsetVertical, trailing: Metrics.rowInsetHorizontal))
                    .listRowSeparator(.hidden)
            }
            .onMove { model.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Metrics.rowHeight)
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowContextMenu(model: model, ids: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { model.togglePreview(id) }
        }
        .onDeleteCommand { model.removeSelected() }
        .onKeyPress(.space, phases: .down) { _ in
            // Space plays only while the list itself has focus (never in a field).
            model.toggleSelectedPreview()
            return .handled
        }
        .padding(.horizontal, Metrics.listSideInset)
        .accessibilityLabel("Queue")
    }
}

/// The right-click menu: acts on every selected row; unavailable items are
/// hidden; three groups (DESIGN_DIRECTION 5, context menu).
struct RowContextMenu: View {
    let model: AppModel
    let ids: Set<UUID>

    var body: some View {
        let commands = model.commands(for: ids)
        let previewable = model.rows.first { ids.contains($0.id) && model.presentation($0).canPreview }
        if let row = previewable {
            Button(model.nowPlayingID == row.id && model.isPreviewPlaying ? "Pause Preview" : "Play Preview") {
                model.togglePreview(row.id)
            }
        }
        ForEach(commands.filter { $0 == .include || $0 == .leaveOut }, id: \.self) { command in
            Button(command.title) { model.perform(command, on: ids) }
        }
        let middle = commands.filter { ![.include, .leaveOut, .remove].contains($0) }
        if !middle.isEmpty {
            Divider()
            ForEach(middle, id: \.self) { command in
                Button(command.title) { model.perform(command, on: ids) }
            }
        }
        Divider()
        Button("Remove from Queue") { model.remove(ids) }
    }
}

/// The 28 pt band above the header: what Return will do, and the compact
/// drop hint with its own Exportify link (4.3 AddArea).
struct AddArea: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(AddInputKind.classify(model.addFieldText).hint)
                .font(Typography.hint)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            DropHint(compact: true, openExportify: model.openExportify)
        }
        .frame(height: Metrics.addAreaHeight)
    }
}

/// "Drop a playlist CSV or paste tracks · Exportify" (compact) or the
/// two-line version for the empty state. "Exportify" is an inline link that
/// only opens the website (D4 4.19).
struct DropHint: View {
    var compact: Bool
    let openExportify: () -> Void

    var body: some View {
        Group {
            if compact {
                Text(Self.text("Drop a playlist CSV or paste tracks · ", "Exportify", ""))
                    .font(Typography.hint)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                VStack(spacing: 6) {
                    Text("Drop a playlist CSV or paste tracks")
                        .font(Typography.emptyBody)
                        .foregroundStyle(Palette.ink)
                    Text(Self.text("For playlists over 100 tracks — export via ", "Exportify", " and drop the CSV here"))
                        .font(Typography.emptyBody)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Palette.ink)
        .environment(\.openURL, OpenURLAction { _ in
            openExportify()
            return .handled
        })
        .help("For playlists over 100 tracks — export via Exportify and drop the CSV here")
    }

    /// Plain text with "Exportify" as an underlined ink link.
    static func text(_ before: String, _ link: String, _ after: String) -> AttributedString {
        var linkText = AttributedString(link)
        linkText.link = AppModel.exportifyURL
        linkText.underlineStyle = .single
        linkText.foregroundColor = Palette.ink
        return AttributedString(before) + linkText + AttributedString(after)
    }
}

/// "Queue 120 · volume · Retry · Clear Queue · 37 of 120" (4.3 QueueHeader).
struct QueueHeader: View {
    @Bindable var model: AppModel
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Queue").font(Typography.queueHeader).foregroundStyle(Palette.ink)
                Text(Formatting.count(model.rows.count))
                    .font(Typography.queueCount.monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
                    .contentTransition(prefs.reduceMotion ? .identity : .numericText())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Queue, \(Formatting.tracks(model.rows.count))")

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .imageScale(.small)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
                Slider(value: $model.settings.previewVolume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: Metrics.volumeWidth)
                    .help("Preview volume")
                    .accessibilityLabel("Preview volume")
                    .accessibilityValue("\(Int((model.settings.previewVolume * 100).rounded())) percent")
            }
            .padding(.leading, 8)

            Spacer(minLength: 8)

            if let retry = model.retryTitle {
                Button(retry) { model.retryFromHeader() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.batch != nil)
            }
            Button("Clear Queue") { model.clearQueue() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canClearQueue)
            if let counter = model.batchCounterText, let batch = model.batch {
                Text(counter)
                    .font(Typography.counter)
                    .foregroundStyle(Palette.inkSecondary)
                    .contentTransition(prefs.reduceMotion ? .identity : .numericText())
                    .animation(Motion.ease(Motion.numbers, reduceMotion: prefs.reduceMotion), value: counter)
                    .accessibilityLabel("\(batch.finished) of \(batch.total) downloaded")
            }
        }
        .frame(height: Metrics.headerHeight)
    }
}

/// Under the header: the system progress bar during a batch, the summary
/// notice after it, nothing otherwise (4.3 BatchSlot).
struct BatchSlot: View {
    let model: AppModel
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        if let batch = model.batch {
            ProgressView(value: Double(batch.finished), total: Double(max(1, batch.total)))
                .progressViewStyle(.linear)
                .labelsHidden()
                .animation(Motion.linear(Motion.progress, reduceMotion: prefs.reduceMotion), value: batch.finished)
                .padding(.bottom, 8)
                .accessibilityLabel("Batch progress")
                .accessibilityValue("\(batch.finished) of \(batch.total) downloaded")
        } else if let summary = model.summary {
            SummaryNotice(summary: summary, model: model)
                .padding(.bottom, 8)
        }
    }
}

/// The notice after a batch (4.10): symbol + sentence + buttons + dismiss.
struct SummaryNotice: View {
    let summary: BatchSummary
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: summary.symbol)
                .foregroundStyle(summary.tone.color)
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(summary.sentence)
                .font(Typography.notice)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(summary.sentence)
            Spacer(minLength: 8)
            ForEach(summary.buttons, id: \.self) { button in
                Button(button.title) { model.performSummaryButton(button) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button {
                model.dismissSummary()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Metrics.removeGlyph, weight: .medium))
                    .foregroundStyle(Palette.inkTertiary)
                    .frame(width: Metrics.removeHit, height: Metrics.removeHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Metrics.noticeHeight)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.noticeRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.noticeRadius).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary.sentence)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
