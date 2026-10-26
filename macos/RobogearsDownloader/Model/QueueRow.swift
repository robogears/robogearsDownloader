import Foundation
import Observation
import RobogearsCore

/// One queue row, observed on its own so a progress tick re-renders that row
/// and nothing else (DESIGN.md §4: "A progress tick must never rebuild the
/// list"). `item` is what gets saved; everything else is for this session.
@MainActor
@Observable
final class QueueRow: Identifiable {
    let id: UUID
    /// The saved part. Changes on state transitions only, never on a tick, so
    /// aggregates that read it (the toolbar count, the header) stay quiet.
    var item: QueueItem

    /// Whole percents while downloading; separate from `item` on purpose.
    var percent: Int = 0
    /// Waiting for the library check (D4 4.20): "Checking library…".
    var isCheckingLibrary = false
    /// The matched library file's length, for "· 4:12 vs 3:58" (this session only).
    var libraryDurationSeconds: Int?
    /// A file for this row already sits in the download folder (D4 2.16).
    var inDownloadFolder = false
    /// Same-name clash or a damaged existing file, from the last batch.
    var problem: Problem?
    /// TIDAL only has a lossy AAC version (the neutral "AAC" badge).
    var isAACOnly = false
    /// Where the saved or skipped file is, for Show in Finder.
    var savedFile: URL?
    /// The row is part of the running batch.
    var inBatch = false
    var preview: PreviewStatus = .none

    enum Problem: Equatable, Sendable {
        case clash(fileName: String)
        case damaged(fileName: String)
    }

    enum PreviewStatus: Equatable, Sendable {
        case none
        case loading
        /// 200 peaks; the bars are drawn from these.
        case ready([Float])
        case unavailable(String)

        var peaks: [Float]? { if case .ready(let p) = self { p } else { nil } }
    }

    init(item: QueueItem) {
        self.id = item.id
        self.item = item
    }
}
