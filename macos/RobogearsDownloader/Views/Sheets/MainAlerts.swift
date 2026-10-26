import AppKit
import SwiftUI

/// The main window's system alerts (4.6, 4.8, 4.9, 4.11; D4 4.8). Words and
/// buttons come from `AlertRoute.content`; the default is always the safe
/// button and Escape picks the cancel button.
struct MainAlerts: ViewModifier {
    @Bindable var model: AppModel

    private var isPresented: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    func body(content: Content) -> some View {
        content.systemAlert(model.alert?.content, isPresented: isPresented) { action in
            model.perform(action)
        }
    }
}

extension View {
    /// Presents an `AlertContent` as a system alert on this window.
    func systemAlert(_ content: AlertContent?, isPresented: Binding<Bool>,
                     perform: @escaping (AlertAction) -> Void) -> some View {
        alert(Text(content?.title ?? ""), isPresented: isPresented, presenting: content) { content in
            ForEach(content.buttons) { button in
                Button(button.title, role: button.role.swiftUI) { perform(button.action) }
                    .keyboardShortcut(button.isDefault ? .defaultAction : nil)
            }
        } message: { content in
            if let message = content.message { Text(message) }
        }
    }
}

extension AlertButton.Role {
    var swiftUI: ButtonRole? {
        switch self {
        case .normal: nil
        case .cancel: .cancel
        case .destructive: .destructive
        }
    }
}

extension AlertContent {
    /// The same alert as an NSAlert: the app-modal quit question when the
    /// window is closed, and the snapshot harness.
    @MainActor
    func makeNSAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        alert.alertStyle = .informational
        let ordered = buttons.filter(\.isDefault) + buttons.filter { !$0.isDefault }
        for spec in ordered {
            let button = alert.addButton(withTitle: spec.title)
            button.keyEquivalent = spec.isDefault ? "\r" : (spec.role == .cancel ? "\u{1b}" : "")
            if spec.role == .destructive { button.hasDestructiveAction = true }
        }
        return alert
    }

    /// The action for an NSAlert response from `makeNSAlert()`.
    func action(for response: NSApplication.ModalResponse) -> AlertAction {
        let ordered = buttons.filter(\.isDefault) + buttons.filter { !$0.isDefault }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return ordered.indices.contains(index) ? ordered[index].action : .dismiss
    }
}
