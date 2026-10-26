import AppKit
import RobogearsCore
import SwiftUI

// The main window's sheets (DESIGN_DIRECTION 4.6–4.8, 4.11). One at a time;
// system backgrounds, system controls and system colours (the black canvas
// is content only). Return fires the default button, Escape and ⌘. cancel.

/// The one sheet at a time on the main window.
struct SheetHost: View {
    let route: SheetRoute
    let model: AppModel

    var body: some View {
        switch route {
        case .signIn(let resume):
            SignInSheet(model: model, resume: resume)
        case .searchResults(let query, let results):
            SearchResultsSheet(model: model, query: query, results: results, pickOneRowID: nil)
        case .pickOne(let rowID, let query, let results):
            SearchResultsSheet(model: model, query: query, results: results, pickOneRowID: rowID)
        case .whatsNew:
            WhatsNewSheet(model: model)
        case .oldFiles:
            OldFilesSheet(model: model)
        }
    }
}

// MARK: - TIDAL sign-in (4.6, D4 1.3)

/// What the sign-in sheet shows. The snapshot harness passes one to render a
/// fixed state without starting a sign-in.
struct SignInSheetState: Equatable {
    var link: URL?
    var code: String?
    var status = "Asking TIDAL for a sign-in link…"
    var failure: String?
    var signedIn = false
}

/// Only a secure tidal.com address is ever opened in the browser (D4 1.3).
enum SignInLink {
    static func isTIDAL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "tidal.com" || host.hasSuffix(".tidal.com")
    }
}

/// Link, Copy Link, TIDAL's short code, one status line; Cancel stops
/// waiting; closes itself 600 ms after "Signed in." (or at once on a click).
struct SignInSheet: View {
    let model: AppModel
    let resume: PendingAdd?
    /// Set by the snapshot harness: shows this state and runs nothing.
    var preset: SignInSheetState?
    @Environment(\.dismiss) private var dismiss
    @State private var state = SignInSheetState()
    @State private var copied = false
    @State private var attempt = 0

    private var shown: SignInSheetState { preset ?? state }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to TIDAL")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Sign in to TIDAL in your browser and click Allow.")
            HStack(spacing: 8) {
                ReadOnlyField(text: shown.link?.absoluteString ?? "", placeholder: "Waiting for a link from TIDAL…",
                              monospaced: true)
                    .accessibilityLabel("Sign-in link")
                Button(action: copyLink) {
                    // Sized for the longer title so "Copied" doesn't shift the field.
                    ZStack {
                        Text("Copy Link").hidden()
                        Text(copied ? "Copied" : "Copy Link")
                    }
                }
                .disabled(shown.link == nil)
            }
            if let code = shown.code {
                Text(verbatim: code)
                    .font(Typography.signInCode)
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            }
            Text(shown.status)
                .font(.callout)
                .foregroundStyle(shown.failure != nil ? Palette.statusFailed : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(shown.status)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if shown.failure != nil {
                    Button("Try Again") {
                        state = SignInSheetState()
                        attempt += 1
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open in Browser") { openLink(automatically: false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(shown.link == nil || shown.signedIn)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        // The task is done once signed in: any click closes at once.
        .onTapGesture { if shown.signedIn { dismiss() } }
        .cancelsOnCommandPeriod { dismiss() }
        .task(id: attempt) {
            guard preset == nil else { return }
            await run()
        }
    }

    private func run() async {
        for await event in model.services.signIn.signIn() {
            switch event {
            case .link(let url, let code):
                state.link = url
                state.code = code
                openLink(automatically: true)
            case .status(let text):
                state.status = text
            case .signedIn(let country):
                state.signedIn = true
                state.status = "Signed in."
                model.signInSucceeded(country: country, resume: resume)
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { dismiss() }
                return
            case .failed(let message):
                state.failure = message
                state.status = message
                return
            }
        }
    }

    /// Opens the link only when it's a secure tidal.com address; says why
    /// otherwise, so the person can copy it instead.
    private func openLink(automatically: Bool) {
        guard let link = state.link else { return }
        guard SignInLink.isTIDAL(link) else {
            if !automatically { state.status = "This link isn't a tidal.com address, so it wasn't opened." }
            return
        }
        if !NSWorkspace.shared.open(link) {
            state.status = "Couldn't open your browser. Copy the link instead."
        }
    }

    private func copyLink() {
        guard let link = shown.link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            copied = false
        }
    }
}

// MARK: - Search results and pick-one (4.7, D4 4.10, 4.11)

/// Up to ten TIDAL results with the queue's library marks. Add Selected is
/// the default and stays unavailable until something is ticked; "In Queue"
/// rows can't be ticked; double-click adds one. In pick-one mode the list's
/// own single selection picks the track that replaces the row in place.
struct SearchResultsSheet: View {
    let model: AppModel
    let query: String
    let results: [SearchResult]
    /// Set in pick-one mode: the chosen track replaces this row in place.
    let pickOneRowID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var refine: String
    @State private var ticked: Set<Int64>
    /// The highlighted row (keyboard; in pick-one mode, the choice).
    @State private var highlight: Int64?

    init(model: AppModel, query: String, results: [SearchResult], pickOneRowID: UUID?,
         presetTicked: Set<Int64> = [], presetRefine: String = "", presetHighlight: Int64? = nil) {
        self.model = model
        self.query = query
        self.results = results
        self.pickOneRowID = pickOneRowID
        _refine = State(initialValue: presetRefine)
        _ticked = State(initialValue: presetTicked)
        _highlight = State(initialValue: presetHighlight)
    }

    private var isPickOne: Bool { pickOneRowID != nil }

    private var shown: [SearchResult] {
        let words = refine.lowercased().split(separator: " ")
        guard !words.isEmpty else { return results }
        return results.filter { r in
            let text = "\(r.track.title) \(r.track.version ?? "") \(r.track.artist) \(r.track.album ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Ticked rows still in the list and not already queued.
    private var chosen: [SearchResult] {
        results.filter { ticked.contains($0.id) && !model.isInQueue($0.track.tidalID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isPickOne ? "Pick the TIDAL track for “\(query)”" : "Results for “\(query)”")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if results.isEmpty {
                Text("No TIDAL results for “\(query)”. Check the spelling or try fewer words.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SearchField(text: $refine, prompt: "Refine")
                    .accessibilityLabel("Refine results")
                list
            }
            HStack {
                if !isPickOne, !chosen.isEmpty {
                    Text("\(Formatting.count(chosen.count)) selected")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isPickOne {
                    Button("Use This Track") { usePicked() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pickedResult == nil)
                } else {
                    Button("Add Selected") { addChosen() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity, minHeight: 360, idealHeight: 480, maxHeight: .infinity)
        .cancelsOnCommandPeriod { dismiss() }
    }

    private var list: some View {
        List(shown, selection: $highlight) { result in
            SearchResultRow(result: result, inQueue: model.isInQueue(result.track.tidalID), isPickOne: isPickOne,
                            isTicked: Binding(get: { ticked.contains(result.id) },
                                              set: { if $0 { ticked.insert(result.id) } else { ticked.remove(result.id) } }))
                .tag(result.id)
                .simultaneousGesture(TapGesture(count: 2).onEnded { addOne(result) })
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds(.disabled)
        // Space ticks the highlighted row (D4 4.11); Return stays the default button.
        .onKeyPress(.space) {
            guard !isPickOne, let id = highlight, let result = results.first(where: { $0.id == id }),
                  !model.isInQueue(result.track.tidalID) else { return .ignored }
            if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
            return .handled
        }
    }

    private var pickedResult: SearchResult? {
        guard let highlight else { return nil }
        return shown.first { $0.id == highlight }
    }

    private func addChosen() {
        guard !chosen.isEmpty else { return }
        model.addSearchResults(chosen, query: query)
        dismiss()
    }

    private func usePicked() {
        guard let rowID = pickOneRowID, let result = pickedResult else { return }
        model.replaceRow(rowID, with: result)
        dismiss()
    }

    private func addOne(_ result: SearchResult) {
        guard !model.isInQueue(result.track.tidalID) else { return }
        if let rowID = pickOneRowID {
            model.replaceRow(rowID, with: result)
        } else {
            model.addSearchResults([result], query: query)
        }
        dismiss()
    }
}

/// One result: checkbox, title with edition, explicit mark and quality, then
/// artist · album · length and the queue's library mark (same symbol and colour).
struct SearchResultRow: View {
    let result: SearchResult
    let inQueue: Bool
    let isPickOne: Bool
    @Binding var isTicked: Bool

    var body: some View {
        let track = result.track
        HStack(spacing: 8) {
            if !isPickOne {
                Toggle("Add \(track.title)", isOn: $isTicked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(inQueue)
            }
            HStack(spacing: 6) {
                (Text(verbatim: track.title).fontWeight(.medium)
                 + Text(verbatim: track.version.map { " — \($0)" } ?? "").foregroundStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if track.explicit { ExplicitMark(ink: .primary) }
                if track.hiRes { QualityBadge(text: "Hi-Res", color: .secondary, stroke: Color(nsColor: .separatorColor)) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text([track.artist, track.album, Formatting.duration(track.durationSeconds)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
            mark(track)
        }
        .padding(.vertical, 2)
        .opacity(inQueue ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(inQueue ? "In Queue" : (isTicked ? "selected" : ""))
    }

    @ViewBuilder
    private func mark(_ track: QueueItem) -> some View {
        if inQueue {
            Text("In Queue").foregroundStyle(.secondary).fixedSize()
        } else if let match = track.libraryMatch {
            let exact = match.kind == .exact
            // Symbol and words in a plain stack, not a Label: the list starts
            // a row's separator under a Label's title, which put it under the
            // mark on these rows and under the title on the rest.
            HStack(spacing: 4) {
                Image(systemName: exact ? "books.vertical" : "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(exact ? "In your library" : "Similar version in library")
            }
            .foregroundStyle(exact ? Color.secondary : Palette.statusSimilar)
            .fixedSize()
            .help("Library: \(Formatting.abbreviatedPath(match.path))")
        }
    }
}

// MARK: - What's New (4.8, D4 5.9)

/// The release notes, Skip This Version, Install on Quit and Install and
/// Relaunch (the default). A copy that can't install itself (a debug build,
/// an unwritable folder) offers the release page instead.
struct WhatsNewSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = model.updateInfo
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("robogears Downloader \(info?.version ?? "") is available")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("You have \(AppModel.currentVersion). Here's what's new.")
                        .foregroundStyle(.secondary)
                }
            }
            GroupBox {
                ScrollView {
                    ReleaseNotesView(markdown: info?.notes ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            .accessibilityLabel("Release notes")
            HStack {
                Button("Skip This Version") {
                    model.skipThisVersion()
                    dismiss()
                }
                .disabled(info == nil)
                Spacer()
                if info?.canSelfInstall ?? true {
                    Button("Install on Quit") {
                        model.chooseInstallOnQuit()
                        dismiss()
                    }
                    .disabled(info == nil || model.installOnQuit)
                    Button("Install and Relaunch") { model.installFromWhatsNew() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(info == nil)
                } else {
                    Button("Open Release Page") {
                        model.openReleasePage()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        // Escape and ⌘. close without choosing (there's no Cancel to press).
        .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).hiddenShortcutButton() }
        .cancelsOnCommandPeriod { dismiss() }
    }
}

/// Release notes as written on GitHub: headings, bullets and paragraphs,
/// with inline bold, italics, code and links.
struct ReleaseNotesView: View {
    let markdown: String

    enum Block: Equatable {
        case heading(String, level: Int)
        case bullet(String)
        case paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text, let level):
                    Text(Self.inline(text))
                        .font(level <= 1 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, index == 0 ? 0 : 6)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").accessibilityHidden(true)
                        Text(Self.inline(text))
                    }
                case .paragraph(let text):
                    Text(Self.inline(text))
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The previous version's files (4.11, D4 5.11)

/// First launch only. A small sheet in alert form, because it carries D4
/// 5.11's three actions plus Keep, one more than an alert holds
/// (`alerts.md`: up to three buttons). Keep is the default (Return, Escape
/// and ⌘.); nothing is touched without a click. Show Old Files and Delete
/// Old Sign-in leave the sheet up so the person can still decide on the rest.
struct OldFilesSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var signInDeleted = false
    @State private var problem: String?

    var body: some View {
        let files = model.services.oldFiles
        let showsDelete = files.hasOldSignIn && !signInDeleted
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files from the previous version are in \(Formatting.abbreviatedPath(files.folder.path)).")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("They aren't used: this version starts fresh, so your old queue, folders and TIDAL sign-in weren't carried over. Sign in and choose your folders in Settings. You can move the old files to the Trash.")
                    if showsDelete {
                        Text("The old TIDAL sign-in is saved as plain text and stays readable in the Trash. Delete Old Sign-in removes it for good.")
                            .foregroundStyle(.secondary)
                    }
                    if signInDeleted {
                        Label("Deleted the old sign-in.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let problem {
                        Text(problem).foregroundStyle(Palette.statusFailed)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Show Old Files") { model.showOldFiles() }
                Spacer()
                if showsDelete {
                    // Can't be undone: red, unlike Move to Trash beside it.
                    Button("Delete Old Sign-in", role: .destructive) {
                        problem = model.deleteOldSignIn()
                        if problem == nil { signInDeleted = true }
                    }
                }
                Button("Move to Trash") {
                    problem = model.trashOldFiles()
                    if problem == nil { dismiss() }
                }
                Button("Keep") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background { Button("Keep") { dismiss() }.keyboardShortcut(.cancelAction).hiddenShortcutButton() }
        .cancelsOnCommandPeriod { dismiss() }
    }
}

// MARK: - Shared pieces

extension View {
    /// ⌘. cancels like Escape (`keyboards.md`: both are Cancel). The Queue
    /// menu's ⌘. reaches a sheet first while a batch runs; this covers the
    /// rest of the time, when that menu item is unavailable.
    func cancelsOnCommandPeriod(_ action: @escaping () -> Void) -> some View {
        background {
            Button("Cancel", action: action)
                .keyboardShortcut(".", modifiers: .command)
                .hiddenShortcutButton()
        }
    }

    /// A button that exists only for its keyboard shortcut.
    func hiddenShortcutButton() -> some View {
        frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)
            .accessibilityHidden(true)
    }
}

/// A system text field that can be selected and copied but not edited (the
/// sign-in link).
struct ReadOnlyField: NSViewRepresentable {
    var text: String
    var placeholder: String
    var monospaced = false

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = false
        field.placeholderString = placeholder
        if monospaced { field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.intrinsicContentSize.height)
    }
}

/// The system search field (magnifying glass and clear button), filtering as
/// the person types.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(string: text)
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
