import Foundation
import RobogearsCore

/// TEMPORARY (see StandIn.swift). A queue that shows every row state of
/// DESIGN_DIRECTION 4.5 at once, for the snapshot harness.
@MainActor
enum StandInSampleQueue {
    struct Sample {
        var rows: [QueueRow]
        /// The row shown playing (pause glyph, playhead at 40 %).
        var playingID: UUID
        /// The row the harness hovers (pointer at 40 % of its waveform).
        var hoverID: UUID
        /// The row shown selected.
        var selectedID: UUID
    }

    static func everyState(folder: URL) -> Sample {
        var rows: [QueueRow] = []
        func add(_ item: QueueItem, peaks: Bool = true, _ configure: (QueueRow) -> Void = { _ in }) -> QueueRow {
            let row = QueueRow(item: item)
            if peaks, let id = item.tidalID { row.preview = .ready(StandIn.peaks(for: id)) }
            configure(row)
            rows.append(row)
            return row
        }

        // Downloading, 42 %, with its preview playing.
        let intro = add(StandIn.item("Intro", version: "Extended Mix", hiRes: true, explicit: true)) {
            $0.item.state = .downloading(percent: 42); $0.percent = 42; $0.inBatch = true
        }
        // Similar version in library (stays included).
        let blue = add(StandIn.item("Blue Lantern", artist: "Another Artist")) {
            $0.item.libraryMatch = .init(kind: .similar, path: "/Volumes/Library/Blue Lantern (Remix).mp3",
                                         libraryTitle: "Blue Lantern (Remix)")
            $0.libraryDurationSeconds = $0.item.durationSeconds.map { $0 - 23 }
        }
        // Waiting inside the running batch.
        _ = add(StandIn.item("Seven", artist: "The Band")) { $0.item.state = .queued; $0.inBatch = true }
        // Done, Hi-Res.
        let done = add(StandIn.item("Northern Lights", artist: "Coastline", hiRes: true)) {
            $0.item.state = .done(quality: "24-bit / 96 kHz")
            $0.savedFile = folder.appendingPathComponent("Northern Lights.flac")
        }
        // Saved as AAC.
        _ = add(StandIn.item("Paper Boats", artist: "Coastline")) {
            $0.item.state = .done(quality: "AAC"); $0.isAACOnly = true
            $0.savedFile = folder.appendingPathComponent("Paper Boats.m4a")
        }
        // Skipped: already in the download folder.
        _ = add(StandIn.item("Late Ferry", artist: "Harbour Lights", hiRes: true)) {
            $0.item.state = .skipped(reason: "Already in your download folder")
            $0.savedFile = folder.appendingPathComponent("Late Ferry.flac")
        }
        // Failed, with its reason kept.
        _ = add(StandIn.item("Glass Houses", explicit: true)) {
            $0.item.state = .failed(reason: "TIDAL couldn't send this track. Try again later.")
        }
        // Not on TIDAL (Spotify source wording would be the second line, but the failure wins).
        _ = add(QueueItem(tidalID: nil, title: "Midnight Static", artist: "DJ Nobody", source: .spotify,
                          originalTitle: "Midnight Static", originalArtist: "DJ Nobody", match: .notOnTIDAL), peaks: false)
        // Couldn't check.
        _ = add(QueueItem(tidalID: nil, title: "Golden Hour", artist: "Sunline", source: .importList,
                          originalTitle: "Golden Hour", originalArtist: "Sunline",
                          match: .couldNotCheck(reason: "TIDAL was busy")), peaks: false)
        // Left out: in your library.
        _ = add(StandIn.item("Slow Motion", hiRes: true)) {
            $0.item.libraryMatch = .init(kind: .exact, path: "/Volumes/Library/Slow Motion.flac", libraryTitle: "Slow Motion")
            $0.item.included = false
        }
        // Left out: different artist on TIDAL.
        _ = add(StandIn.item("Satellite", artist: "Other Artist")) {
            $0.item.match = .differentArtist(tidalArtist: "Other Artist")
            $0.item.included = false
            $0.item.source = .spotify
            $0.item.originalTitle = "Satellite"
            $0.item.originalArtist = "Placeholder Artist"
        }
        // In your download folder (added during the batch).
        _ = add(StandIn.item("Afterglow", hiRes: true)) { $0.inDownloadFolder = true }
        // Clash.
        _ = add(StandIn.item("Echo Park")) { $0.problem = .clash(fileName: "Echo Park.flac") }
        // Damaged file.
        _ = add(StandIn.item("Driftwood")) {
            $0.problem = .damaged(fileName: "Driftwood.flac")
            $0.savedFile = folder.appendingPathComponent("Driftwood.flac")
        }
        // Checking library (no peaks yet: nothing drawn).
        _ = add(StandIn.item("Hollow", artist: "New Artist"), peaks: false) { $0.isCheckingLibrary = true }
        // Preview unavailable.
        _ = add(StandIn.item("Undertow", hiRes: true), peaks: false) {
            $0.preview = .unavailable("TIDAL didn't send a preview for this track. Try again.")
        }
        // Waiting, no batch (added during the batch), with the Spotify source wording.
        _ = add(StandIn.item("Lanterns", artist: "Sample Choir", hiRes: true, source: .spotify)) {
            $0.item.originalTitle = "Lanterns (feat. Sample Choir)"
            $0.item.originalArtist = "Sample Choir"
        }
        // Left out by the person.
        _ = add(StandIn.item("Tidepool", artist: "Coastline")) { $0.item.included = false }
        // Long content: the waveform reaches 0 before the title truncates.
        _ = add(StandIn.item("The Longest Possible Title For A Track That Keeps Going And Going Well Past Any Sensible Length",
                             version: "Original Mix",
                             artist: "Placeholder Artist, Another Artist, The Band, Coastline, Sunline, Harbour Lights, Sample Choir, New Artist, Other Artist, DJ Nobody"))
        // Plain rows to fill the window.
        for entry in StandIn.catalog.suffix(5) {
            _ = add(StandIn.item(entry.title, version: entry.version, artist: entry.artist, hiRes: entry.hiRes, explicit: entry.explicit))
        }
        return Sample(rows: rows, playingID: intro.id, hoverID: blue.id, selectedID: done.id)
    }

    /// A few rows waiting or failed, as they look after a batch.
    static func afterBatch(failed: Int, waiting: Int) -> [QueueRow] {
        var rows: [QueueRow] = []
        let names = StandIn.catalog
        for i in 0..<(failed + waiting) {
            let e = names[(i + 3) % names.count]
            let row = QueueRow(item: StandIn.item(e.title, version: e.version, artist: e.artist, hiRes: e.hiRes, explicit: e.explicit))
            if let id = row.item.tidalID { row.preview = .ready(StandIn.peaks(for: id)) }
            if i < failed { row.item.state = .failed(reason: "TIDAL couldn't send this track. Try again later.") }
            rows.append(row)
        }
        return rows
    }

    static let activity: [(ActivityLog.Kind, String)] = [
        (.added, "Added 120 tracks from Spotify link (3 not on TIDAL)."),
        (.library, "Library check: 4 tracks already in your library (left out), 2 with a similar version."),
        (.notice, "Downloading 120 tracks into ~/Music/TIDAL."),
        (.saved, "Saved Northern Lights.flac (24-bit / 96 kHz)."),
        (.saved, "Saved Paper Boats.m4a (AAC: TIDAL has no lossless version)."),
        (.notice, "Skipped Late Ferry.flac: already in your download folder."),
        (.failed, "Glass Houses: TIDAL couldn't send this track. Try again later."),
        (.failed, "Echo Park wasn't downloaded: a different song is already saved as Echo Park.flac."),
        (.warning, "Preview of Undertow: TIDAL didn't send a preview for this track. Try again."),
        (.update, "robogears Downloader 0.1.32 is available."),
    ]
}
