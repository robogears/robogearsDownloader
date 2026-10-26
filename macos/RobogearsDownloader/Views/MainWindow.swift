import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window (DESIGN_DIRECTION 4.1): system title bar and toolbar, the
/// canvas content (queue above, activity below), the adding cover, sheets
/// and alerts. The whole content area accepts drops.
struct MainWindow: View {
    @Bindable var model: AppModel
    enum Focus: Hashable { case addField }

    @FocusState private var focus: Focus?
    @State private var isDropTargeted = false
    @State private var windowWidth: CGFloat = Metrics.windowDefault.width
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .frame(minWidth: Metrics.windowMinimum.width, minHeight: Metrics.windowMinimum.height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .toolbar { MainToolbar(model: model, focus: $focus, fieldWidth: Metrics.addFieldWidth(forWindowWidth: windowWidth)) }
            .navigationTitle("robogears Downloader")
            .toolbar(removing: .title)
            .sheet(item: $model.sheet) { route in
                SheetHost(route: route, model: model)
                    .resolvingDisplayPreferences()
            }
            .modifier(MainAlerts(model: model))
            .background(WindowReader { model.mainWindow = $0 })
            .onAppear {
                model.undoManager = undoManager
                model.openMainWindowAction = { openWindow(id: "main") }
                model.start()
            }
            .onChange(of: undoManager) { _, manager in model.undoManager = manager }
            .onChange(of: model.focusAddFieldRequest) { focus = .addField }
            .resolvingDisplayPreferences()
    }

    /// The canvas content, without window-level modifiers (the snapshot
    /// harness renders this inside its own off-screen window).
    var content: some View {
        MainContent(model: model, isDropTargeted: $isDropTargeted)
    }
}

/// The canvas: queue area and activity panel in a native split, plus the
/// drop outline and the adding cover.
struct MainContent: View {
    @Bindable var model: AppModel
    @Binding var isDropTargeted: Bool
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.displayOverrides) private var overrides
    @Environment(\.snapshotHover) private var hover

    var body: some View {
        ActivitySplit(showsBottom: model.isActivityVisible,
                      onVisibilityChange: { model.isActivityVisible = $0 },
                      remembersHeight: model.persists,
                      top: pane(QueueArea(model: model).disabled(model.adding != nil)),
                      bottom: pane(ActivityPanel(log: model.activity)))
            .accessibilityHidden(model.adding != nil)
            .background(Palette.canvas, ignoresSafeAreaEdges: [])
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: Metrics.dragOutlineRadius)
                        .strokeBorder(Palette.ink, lineWidth: Metrics.dragOutline)
                        .padding(Metrics.dragOutline)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if let adding = model.adding {
                    AddingCover(state: adding, cancel: model.cancelAdd)
                        .transition(prefs.reduceMotion ? .identity : .opacity)
                }
            }
            .animation(Motion.ease(Motion.cover, reduceMotion: prefs.reduceMotion), value: model.adding?.id)
    }

    /// Each pane is its own SwiftUI tree inside the split, so it carries the
    /// window's overrides, accepts drops and handles Paste itself.
    private func pane<V: View>(_ content: V) -> some View {
        content
            .environment(\.displayOverrides, overrides)
            .environment(\.snapshotHover, hover)
            .resolvingDisplayPreferences()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .accessibilityHidden(model.adding != nil)
            .onDrop(of: [.fileURL, .url, .plainText], delegate: QueueDropDelegate(model: model, isTargeted: $isDropTargeted))
            .onPasteCommand(of: [.fileURL, .plainText, .commaSeparatedText, .utf8PlainText]) { providers in
                model.paste(providers)
            }
    }
}

/// Accepts tracklists and links anywhere on the content; anything else shows
/// the not-allowed pointer and, if dropped, a reason (D4 4.8).
struct QueueDropDelegate: DropDelegate {
    let model: AppModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .url, .plainText])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info) && model.adding == nil && !model.isModalUp
    }

    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let ok = validateDrop(info: info) && model.adding == nil && !model.isModalUp
        return DropProposal(operation: ok ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard model.adding == nil else {
            model.refuse("Another add is still running. Wait for it to finish or cancel it, then drop again.")
            return false
        }
        return model.drop(info.itemProviders(for: [.fileURL, .url, .plainText]))
    }
}

/// Hands the hosting NSWindow to the model once the view is in it (the quit
/// question, the end-of-batch attention request and reopening use it).
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
