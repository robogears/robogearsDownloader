import Foundation
import Observation

/// The activity panel's record (DESIGN_DIRECTION 4.3): adds, results with
/// reasons, library and update events. Capped at 2,000 lines, oldest
/// trimmed. Lines are plain sentences: never a signed link, a raw reply or
/// the account's name (DESIGN.md §7).
@MainActor
@Observable
final class ActivityLog {
    enum Kind: Sendable, Equatable {
        case added, saved, failed, warning, retry, library, update, notice, search, importList, stopped

        /// The SF Symbol in the panel's symbol column.
        var symbol: String {
            switch self {
            case .added: "plus"
            case .saved: "checkmark"
            case .failed: "xmark.circle"
            case .warning: "exclamationmark.triangle"
            case .retry: "arrow.clockwise"
            case .library: "books.vertical"
            case .update: "arrow.down.circle"
            case .notice: "info.circle"
            case .search: "magnifyingglass"
            case .importList: "doc.text"
            case .stopped: "stop.circle"
            }
        }

        /// Results read in ink, errors in red, warnings in amber, the rest secondary.
        var tone: Tone {
            switch self {
            case .saved, .added: .ink
            case .failed: .failed
            case .warning: .similar
            default: .secondary
            }
        }
    }

    struct Entry: Identifiable, Sendable, Equatable {
        let id: Int
        let kind: Kind
        let text: String
        let date: Date
    }

    private(set) var entries: [Entry] = []
    /// Bumped by Clear so the text view starts over.
    private(set) var generation = 0
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored let capacity: Int

    init(capacity: Int = Metrics.activityMaxLines) {
        self.capacity = capacity
    }

    func add(_ kind: Kind, _ text: String, date: Date = Date()) {
        entries.append(Entry(id: nextID, kind: kind, text: text, date: date))
        nextID += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll()
        generation += 1
    }
}
