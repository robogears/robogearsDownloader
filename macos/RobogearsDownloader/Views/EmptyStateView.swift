import SwiftUI

/// Shown instead of the list when the queue has no rows (4.3 EmptyState).
/// Priority: signed out › no download folder › ready. No sheet at launch.
struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Button {
                // The joke sound lives here and in About (Q3); never in the toolbar.
                model.sounds.play(.brandFart)
            } label: {
                BrandGlyphView()
                    .frame(width: Metrics.glyph, height: Metrics.glyph)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            content
        }
        .frame(maxWidth: Metrics.emptyMaxWidth)
        .padding(.horizontal, Metrics.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if !model.isSignedIn {
            title(model.signInState == .invalid ? "Your TIDAL sign-in is no longer valid" : "Not signed in to TIDAL")
            body("Sign in to add tracks from links, searches and tracklists.")
            Button(model.signInState == .invalid ? "Sign In Again…" : "Sign In…") { model.showSignIn() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        } else if model.settings.downloadFolder == nil {
            title("Choose a download folder to start downloading.")
            body("Every download goes here directly — no subfolders.")
            Button("Choose Folder…") { model.chooseDownloadFolder() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        } else {
            title("Downloads go to \(model.downloadFolderDisplayPath ?? "your download folder")")
            DropHint(compact: false, openExportify: model.openExportify)
                .padding(Metrics.dropBoxPadding)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: Metrics.dropBoxRadius).strokeBorder(Palette.hairline, lineWidth: 1))
                .padding(.top, 6)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Typography.emptyTitle)
            .foregroundStyle(Palette.ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(Typography.emptyBody)
            .foregroundStyle(Palette.inkSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The cover over the content while an add is in flight (4.11): a system
/// material (opaque canvas under Reduce Transparency), a spinner, a loading
/// line until a count is known, and Cancel (Escape, ⌘.).
struct AddingCover: View {
    let state: AddingState
    let cancel: () -> Void
    @FocusState private var cancelFocused: Bool
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        ZStack {
            if prefs.reduceTransparency {
                Palette.canvas
            } else {
                Rectangle().fill(.regularMaterial)
            }
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                line
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
            }
            .padding(24)
        }
        .onAppear { cancelFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var line: some View {
        if let count = state.countText {
            Text(count)
                .font(Typography.coverText)
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityLabel(count.replacingOccurrences(of: " / ", with: " of "))
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            TimelineView(.periodic(from: state.startedAt, by: Motion.loadingLineInterval)) { context in
                let tick = Int(context.date.timeIntervalSince(state.startedAt) / Motion.loadingLineInterval)
                Text(LoadingLines.line(seed: state.seed, tick: tick))
                    .font(Typography.coverText)
                    .foregroundStyle(Palette.inkSecondary)
                    .id(tick)
                    .transition(prefs.reduceMotion ? .identity : .opacity)
                    .animation(Motion.ease(Motion.cover, reduceMotion: prefs.reduceMotion), value: tick)
            }
        }
    }
}
