import AppKit
import RobogearsCore
import SwiftUI

// First working versions of the sheets the main window opens. They use the
// system's own backgrounds and controls (the black canvas is content only).
// The sheet pass refines them against DESIGN_DIRECTION 4.6–4.8.

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
        }
    }
}

/// TIDAL sign-in (4.6): link, short code, one status line; Cancel stops polling.
struct SignInSheet: View {
    let model: AppModel
    let resume: PendingAdd?
    @Environment(\.dismiss) private var dismiss
    @State private var link: URL?
    @State private var code: String?
    @State private var status = "Asking TIDAL for a sign-in link…"
    @State private var failure: String?
    @State private var signedIn = false
    @State private var copied = false
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to TIDAL").font(.headline)
            Text("Sign in to TIDAL in your browser and click Allow.")
            HStack(spacing: 8) {
                Text(link?.absoluteString ?? " ")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                    .accessibilityLabel("Sign-in link")
                Button(copied ? "Copied" : "Copy Link") { copyLink() }
                    .disabled(link == nil)
            }
            if let code {
                Text(code)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            }
            Text(status)
                .font(.callout)
                .foregroundStyle(failure != nil ? Palette.statusFailed : Color.secondary)
                .lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if failure != nil {
                    Button("Try Again") { failure = nil; attempt += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open in Browser") { if let link { NSWorkspace.shared.open(link) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(link == nil || signedIn)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .contentShape(Rectangle())
        .onTapGesture { if signedIn { dismiss() } }
        .task(id: attempt) { await run() }
    }

    private func run() async {
        status = "Asking TIDAL for a sign-in link…"
        for await event in model.services.signIn.signIn() {
            switch event {
            case .link(let url, let code):
                link = url
                self.code = code
            case .status(let text):
                status = text
            case .signedIn(let country):
                signedIn = true
                status = "Signed in."
                model.signInSucceeded(country: country, resume: resume)
                try? await Task.sleep(for: .milliseconds(600))
                dismiss()
                return
            case .failed(let message):
                failure = message
                status = message
                return
            }
        }
    }

    private func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            copied = false
        }
    }
}

/// Search results (4.7) and pick-one mode for a "Not on TIDAL" row.
struct SearchResultsSheet: View {
    let model: AppModel
    let query: String
    let results: [SearchResult]
    /// Set in pick-one mode: the chosen track replaces this row in place.
    let pickOneRowID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var refine = ""
    @State private var ticked: Set<Int64> = []
    @State private var picked: Int64?

    private var shown: [SearchResult] {
        let words = refine.lowercased().split(separator: " ")
        guard !words.isEmpty else { return results }
        return results.filter { r in
            let text = "\(r.track.title) \(r.track.version ?? "") \(r.track.artist) \(r.track.album ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pickOneRowID == nil ? "Results for “\(query)”" : "Pick the TIDAL track for “\(query)”")
                .font(.headline)
            if !results.isEmpty {
                TextField("Refine", text: $refine)
                    .textFieldStyle(.roundedBorder)
            }
            if results.isEmpty {
                Text("No TIDAL results for “\(query)”. Check the spelling or try fewer words.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { result in
                    resultRow(result)
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
            }
            HStack {
                if pickOneRowID == nil {
                    Text(ticked.isEmpty ? "" : "\(Formatting.count(ticked.count)) selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let rowID = pickOneRowID {
                    Button("Use This Track") {
                        if let id = picked, let result = results.first(where: { $0.id == id }) {
                            model.replaceRow(rowID, with: result)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil)
                } else {
                    Button("Add Selected") {
                        model.addSearchResults(results.filter { ticked.contains($0.id) }, query: query)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticked.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 480)
    }

    @ViewBuilder
    private func resultRow(_ result: SearchResult) -> some View {
        let track = result.track
        let inQueue = model.isInQueue(track.tidalID)
        HStack(spacing: 8) {
            if pickOneRowID == nil {
                Toggle(isOn: Binding(get: { ticked.contains(result.id) },
                                     set: { if $0 { ticked.insert(result.id) } else { ticked.remove(result.id) } })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .disabled(inQueue)
                .accessibilityLabel("Select \(track.title)")
            } else {
                Image(systemName: picked == result.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked == result.id ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            let name = Text(verbatim: track.title).fontWeight(.medium)
            let edition = Text(verbatim: track.version.map { " — \($0)" } ?? "").foregroundStyle(.secondary)
            Text("\(name)\(edition)")
                .lineLimit(1)
            if track.explicit { ExplicitMark(ink: .primary) }
            if track.hiRes { QualityBadge(text: "Hi-Res", color: .secondary) }
            Spacer(minLength: 8)
            Text([track.artist, track.album, Formatting.duration(track.durationSeconds)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if inQueue {
                Text("In Queue").foregroundStyle(.secondary)
            } else if let match = track.libraryMatch {
                Label(match.kind == .exact ? "In your library" : "Similar version in library",
                      systemImage: match.kind == .exact ? "books.vertical" : "exclamationmark.triangle.fill")
                    .foregroundStyle(match.kind == .exact ? Color.secondary : Palette.statusSimilar)
                    .labelStyle(.titleAndIcon)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !inQueue else { return }
            if let rowID = pickOneRowID {
                model.replaceRow(rowID, with: result)
            } else {
                model.addSearchResults([result], query: query)
            }
            dismiss()
        }
        .onTapGesture {
            if pickOneRowID != nil { picked = result.id }
            else if !inQueue {
                if ticked.contains(result.id) { ticked.remove(result.id) } else { ticked.insert(result.id) }
            }
        }
    }
}

/// What's New (4.8): the release notes and Install and Relaunch.
struct WhatsNewSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's New in robogears Downloader \(model.update?.available?.version ?? "")").font(.headline)
            ScrollView {
                Text((try? AttributedString(markdown: model.update?.available?.notes ?? "",
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(model.update?.available?.notes ?? ""))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Not Now", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") {
                    dismiss()
                    model.updateControlClicked()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.update?.available == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}
