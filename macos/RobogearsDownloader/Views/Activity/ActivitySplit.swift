import AppKit
import SwiftUI

/// The queue above, the activity panel below, in a native NSSplitView
/// (DESIGN_DIRECTION 4.1, Q2): the panel opens at 160 pt, keeps its height
/// when the window resizes (the queue takes the change), can be dragged
/// between 72 pt and the queue's 220 pt minimum, collapses by dragging the
/// divider down or with View › Hide Activity, and remembers its height
/// (one defaults key; the snapshot harness never writes it).
///
/// SwiftUI's VSplitView was tried first: it re-applies "children get their
/// minimum" on every layout, so the panel snapped back to its floor.
struct ActivitySplit<Top: View, Bottom: View>: NSViewRepresentable {
    var showsBottom: Bool
    /// The divider was dragged to collapse or reopen the panel.
    var onVisibilityChange: (Bool) -> Void
    /// Off in the snapshot harness (nothing is saved there).
    var remembersHeight = true
    var top: Top
    var bottom: Bottom

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitView {
        let split = SplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        let topHost = NSHostingView(rootView: AnyView(top))
        let bottomHost = NSHostingView(rootView: AnyView(bottom))
        for host in [topHost, bottomHost] {
            host.sizingOptions = []
            split.addArrangedSubview(host)
        }
        // The queue takes window resizes; the panel keeps its height.
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue + 10),
                                 forSubviewAt: 1)
        split.heightKey = remembersHeight ? "ActivityPanelHeight" : nil
        context.coordinator.split = split
        context.coordinator.onVisibilityChange = onVisibilityChange
        split.wantsBottomVisible = showsBottom
        return split
    }

    func updateNSView(_ split: SplitView, context: Context) {
        context.coordinator.onVisibilityChange = onVisibilityChange
        (split.arrangedSubviews[0] as? NSHostingView<AnyView>)?.rootView = AnyView(top)
        (split.arrangedSubviews[1] as? NSHostingView<AnyView>)?.rootView = AnyView(bottom)
        if split.wantsBottomVisible != showsBottom {
            split.wantsBottomVisible = showsBottom
            split.applyBottomVisibility()
        }
    }

    final class SplitView: NSSplitView {
        var wantsBottomVisible = true
        /// Where the panel's height is remembered (nil: not remembered).
        var heightKey: String?
        private var placedInitially = false
        fileprivate var lastBottomHeight = Metrics.activityDefault

        override func layout() {
            super.layout()
            guard !placedInitially, bounds.height > 0, arrangedSubviews.count == 2 else { return }
            placedInitially = true
            if let heightKey, StorageLocation.values.double(forKey: heightKey) >= Metrics.activityMinimum {
                lastBottomHeight = StorageLocation.values.double(forKey: heightKey)
            }
            setPosition(bounds.height - lastBottomHeight - dividerThickness, ofDividerAt: 0)
            applyBottomVisibility()
        }

        /// Remembers the panel's height after a drag (not while collapsed).
        fileprivate func rememberHeight() {
            guard placedInitially, arrangedSubviews.count == 2, !isSubviewCollapsed(arrangedSubviews[1]) else { return }
            let height = arrangedSubviews[1].frame.height
            guard height >= Metrics.activityMinimum else { return }
            lastBottomHeight = height
            if let heightKey { StorageLocation.values.set(Double(height), forKey: heightKey) }
        }

        func applyBottomVisibility() {
            guard arrangedSubviews.count == 2, bounds.height > 0 else { return }
            let bottom = arrangedSubviews[1]
            let collapsed = isSubviewCollapsed(bottom)
            if wantsBottomVisible, collapsed {
                setPosition(bounds.height - lastBottomHeight - dividerThickness, ofDividerAt: 0)
            } else if !wantsBottomVisible, !collapsed {
                lastBottomHeight = max(Metrics.activityMinimum, bottom.frame.height)
                setPosition(bounds.height, ofDividerAt: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var split: SplitView?
        var onVisibilityChange: (Bool) -> Void = { _ in }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            subview === splitView.arrangedSubviews.last
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(proposedMinimumPosition, 220)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            min(proposedMaximumPosition, splitView.bounds.height - Metrics.activityMinimum - splitView.dividerThickness)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let split, split.arrangedSubviews.count == 2 else { return }
            split.rememberHeight()
            let visible = !split.isSubviewCollapsed(split.arrangedSubviews[1])
            guard visible != split.wantsBottomVisible else { return }
            split.wantsBottomVisible = visible
            let report = onVisibilityChange
            Task { @MainActor in report(visible) }
        }
    }
}
