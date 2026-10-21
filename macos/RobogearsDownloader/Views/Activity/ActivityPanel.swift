import AppKit
import SwiftUI

/// The collapsible bottom panel (DESIGN_DIRECTION 4.3, Q2): "Activity" and
/// Clear, then a read-only, selectable, monospaced record with a symbol column.
struct ActivityPanel: View {
    let log: ActivityLog
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity")
                    .font(Typography.activityHeader)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear") { log.clear() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, Metrics.contentInset)
            .frame(height: Metrics.activityHeader + 4)
            ActivityTextView(entries: log.entries, generation: log.generation,
                             appearanceKey: "\(colorScheme)-\(prefs.increasedContrast)")
                .padding(.leading, Metrics.contentInset - 4)
        }
        .background(Palette.canvas)
    }
}

/// An NSTextView: selectable, never editable, appended to line by line (the
/// list is never re-laid out per line), trimmed with the log's 2,000 cap,
/// and scrolled to the end only when it was already at the end.
struct ActivityTextView: NSViewRepresentable {
    let entries: [ActivityLog.Entry]
    let generation: Int
    /// Changes with the appearance so the baked colours are redrawn.
    let appearanceKey: String

    final class Coordinator {
        var renderedIDs: [Int] = []
        var generation = -1
        var appearanceKey = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.isRichText = true
            text.textContainerInset = NSSize(width: 0, height: 2)
            text.textContainer?.lineFragmentPadding = 4
            text.setAccessibilityRole(.textArea)
            text.setAccessibilityLabel("Activity")
            text.usesFindBar = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        let c = context.coordinator

        // A Clear, or an appearance change (colours are baked into the text), starts over.
        if c.generation != generation || c.appearanceKey != appearanceKey {
            storage.setAttributedString(NSAttributedString())
            c.renderedIDs = []
            c.generation = generation
            c.appearanceKey = appearanceKey
        }

        let atBottom = isAtBottom(scroll)

        // Trim lines the log dropped from the front.
        if let firstKept = entries.first?.id, let firstShown = c.renderedIDs.first, firstShown < firstKept {
            let dropCount = c.renderedIDs.prefix { $0 < firstKept }.count
            let string = storage.string as NSString
            var location = 0
            for _ in 0..<dropCount {
                let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(lineRange)
            }
            storage.deleteCharacters(in: NSRange(location: 0, length: min(location, storage.length)))
            c.renderedIDs.removeFirst(dropCount)
        }

        let lastShown = c.renderedIDs.last ?? -1
        let fresh = entries.filter { $0.id > lastShown }
        guard !fresh.isEmpty else { return }
        let appended = NSMutableAttributedString()
        for entry in fresh { appended.append(Self.line(for: entry)) }
        storage.append(appended)
        c.renderedIDs += fresh.map(\.id)
        // After layout, so the first fill also opens at the newest line.
        if atBottom { DispatchQueue.main.async { text.scrollToEndOfDocument(nil) } }
    }

    private func isAtBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return true }
        let visible = scroll.contentView.documentVisibleRect
        return visible.maxY >= document.bounds.maxY - 4
    }

    /// Symbol column (1.5 em) then the sentence, wrapped lines indented under
    /// the text. Colours stay dynamic (asset colours resolve when the text
    /// view draws, in its own appearance); the symbol is drawn the same way.
    static func line(for entry: ActivityLog.Entry) -> NSAttributedString {
        let size = Typography.activityPointSize
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let column = size * 1.5
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        paragraph.headIndent = column
        paragraph.lineSpacing = 2
        let color = entry.kind.tone.nsColor
        let result = NSMutableAttributedString()
        if let symbol = symbolImage(entry.kind.symbol, pointSize: size - 1, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height)
            result.append(NSAttributedString(attachment: attachment))
        }
        result.append(NSAttributedString(string: "\t\(entry.text)\n"))
        result.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: result.length))
        return result
    }

    /// An SF Symbol tinted with a dynamic colour at draw time, so it follows
    /// Light, Dark and Increase Contrast like the text beside it.
    private static func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.cacheMode = .never
        return image
    }
}
