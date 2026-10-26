import SwiftUI

/// Three items in two groups (4.2): the Add field in the centre; the update
/// control (only when one exists) and the one prominent action trailing,
/// with a fixed space between the two text buttons.
struct MainToolbar: ToolbarContent {
    @Bindable var model: AppModel
    var focus: FocusState<MainWindow.Focus?>.Binding
    /// 320 pt at the 720 pt minimum, 560 pt from about 960 pt (4.2).
    var fieldWidth: CGFloat

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            AddField(model: model, focus: focus)
                .frame(width: fieldWidth)
        }
        ToolbarItem(placement: .primaryAction) {
            UpdateControl(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            PrimaryActionButton(model: model)
        }
    }
}

/// "Paste a link or search TIDAL": Return adds or searches; ⌘L focuses it.
struct AddField: View {
    @Bindable var model: AppModel
    var focus: FocusState<MainWindow.Focus?>.Binding

    var body: some View {
        TextField("Add a link or search TIDAL", text: $model.addFieldText,
                  prompt: Text("Paste a link or search TIDAL"))
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.submitAddField() }
            .focused(focus, equals: .addField)
            .disabled(model.adding != nil)
            .help("Paste a Spotify or TIDAL link, or type a song name, then press Return")
            .accessibilityLabel("Add a link or search TIDAL")
    }
}

/// "Update to 0.1.32" → "Downloading 42%" → "Relaunching…". Hidden until an
/// update exists; fades in once (200 ms), never pulses.
struct UpdateControl: View {
    let model: AppModel
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        Group {
            if let state = model.updateControl {
                Button {
                    model.updateControlClicked()
                } label: {
                    Text(state.title).monospacedDigit()
                }
                .buttonStyle(.bordered)
                .disabled(!state.isEnabled)
                .help(state.help)
                .transition(prefs.reduceMotion ? .identity : .opacity)
            }
        }
        .animation(Motion.ease(Motion.fadeIn, reduceMotion: prefs.reduceMotion), value: model.updateControl != nil)
        .padding(.trailing, model.updateControl != nil ? 8 : 0)
    }
}

/// Download All / Download (47) / Stop Downloads (4.2). Return never
/// triggers it; ⌘↩ does, from the menu.
struct PrimaryActionButton: View {
    let model: AppModel
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        if model.batch != nil {
            Button("Stop Downloads") { model.stopDownloads() }
                .buttonStyle(.bordered)
                .help("Stop downloading (⌘.)")
        } else {
            Button {
                model.downloadAll()
            } label: {
                Text(model.downloadButtonTitle)
                    .contentTransition(prefs.reduceMotion ? .identity : .numericText())
                    .inkProminentLabel()
            }
            .inkProminent()
            .disabled(model.rows.isEmpty || model.downloadableCount == 0 || model.isSigningIn)
            .animation(Motion.ease(Motion.numbers, reduceMotion: prefs.reduceMotion), value: model.downloadButtonTitle)
            .help("Download every included track (⌘↩)")
        }
    }
}
