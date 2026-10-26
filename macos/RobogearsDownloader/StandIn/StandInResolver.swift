import Foundation
import RobogearsCore

/// TEMPORARY (see StandIn.swift). Turns links, lines and tracklists into rows
/// from the invented catalogue, with a short pause per track so the adding
/// cover's count and Cancel can be seen working.
struct StandInResolver: TrackResolving {
    var pacing: Duration = .milliseconds(45)

    func add(_ source: AddSource) -> AsyncStream<AddEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(source, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ source: AddSource, _ out: AsyncStream<AddEvent>.Continuation) async {
        switch source {
        case .link(let link):
            let lower = link.lowercased()
            guard lower.contains("tidal.com") || lower.contains("spotify") else {
                out.yield(.failed("That link isn't from TIDAL or Spotify. Paste a TIDAL or Spotify track, album or playlist link."))
                return
            }
            let isSpotify = lower.contains("spotify")
            let count: Int
            if lower.contains("playlist") { count = isSpotify ? 100 : 36 }
            else if lower.contains("album") { count = 9 }
            else { count = 1 }
            try? await Task.sleep(for: .milliseconds(600))
            var made: [QueueItem] = []
            for i in 0..<count {
                if Task.isCancelled { return }
                let entry = StandIn.catalog[i % StandIn.catalog.count]
                let round = i / StandIn.catalog.count
                let title = round == 0 ? entry.title : "\(entry.title) \(round + 1)"
                var item = StandIn.item(title, version: entry.version, artist: entry.artist,
                                        hiRes: entry.hiRes, explicit: entry.explicit, source: isSpotify ? .spotify : .tidal)
                if isSpotify {
                    item.originalTitle = entry.version.map { "\(title) - \($0)" } ?? title
                    item.originalArtist = entry.artist
                }
                made.append(item)
                if count > 1 {
                    out.yield(.progress(done: i + 1, total: count))
                    try? await Task.sleep(for: pacing)
                }
                if made.count == 10 { out.yield(.items(made)); made = [] }
            }
            out.yield(.items(made))
            if isSpotify && count == 100 { out.yield(.capped(playlistName: "Late Ferry")) }
            out.yield(.finished(sourceName: isSpotify ? "Spotify link" : "TIDAL link"))
        case .line(let line):
            try? await Task.sleep(for: .milliseconds(400))
            out.yield(.items([match(line, source: .importList)]))
            out.yield(.finished(sourceName: "pasted text"))
        case .tracklist(let text, let name):
            let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("track name") && !$0.lowercased().hasPrefix("title") }
            var batch: [QueueItem] = []
            for (i, line) in lines.enumerated() {
                if Task.isCancelled { break }
                batch.append(match(line, source: .importList))
                out.yield(.progress(done: i + 1, total: lines.count))
                if batch.count == 10 { out.yield(.items(batch)); batch = [] }
                try? await Task.sleep(for: pacing)
            }
            out.yield(.items(batch))
            if !Task.isCancelled { out.yield(.finished(sourceName: name ?? "pasted text")) }
        }
    }

    /// "Title - Artist" (or a CSV row) → a row; some deterministic misses.
    private func match(_ line: String, source: QueueItem.Source) -> QueueItem {
        let separators = [" - ", " – ", " — ", " | ", "\t", ","]
        var title = line, artist = ""
        for sep in separators where line.contains(sep) {
            let parts = line.components(separatedBy: sep).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            title = parts[0]
            artist = parts.count > 1 ? parts[1] : ""
            break
        }
        let h = StandIn.hash(title.lowercased())
        if h % 9 == 0 {
            return QueueItem(tidalID: nil, title: title, artist: artist, source: source,
                             originalTitle: title, originalArtist: artist, match: .notOnTIDAL)
        }
        if h % 13 == 0 {
            return QueueItem(tidalID: nil, title: title, artist: artist, source: source,
                             originalTitle: title, originalArtist: artist, match: .couldNotCheck(reason: "TIDAL was busy"))
        }
        var item = StandIn.item(title, artist: artist.isEmpty ? "Placeholder Artist" : artist,
                                hiRes: h % 3 == 0, explicit: h % 11 == 0, source: source)
        item.originalTitle = title
        item.originalArtist = artist
        return item
    }

    func search(_ query: String) async throws -> [SearchResult] {
        try await Task.sleep(for: .milliseconds(500))
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.lowercased() == "nothing" { return [] }
        let variants: [(String?, String, Bool, Bool)] = [
            (nil, "Placeholder Artist", true, false),
            ("Extended Mix", "Placeholder Artist", true, true),
            ("Live", "Placeholder Artist", false, false),
            ("Radio Edit", "Another Artist", false, false),
            (nil, "The Band", false, false),
            ("Remastered", "Coastline", true, false),
        ]
        return variants.map { version, artist, hiRes, explicit in
            SearchResult(track: StandIn.item(q.capitalized, version: version, artist: artist,
                                             hiRes: hiRes, explicit: explicit, source: .search))
        }
    }

    func matchAgain(_ item: QueueItem) async -> QueueItem {
        try? await Task.sleep(for: .milliseconds(500))
        var matched = StandIn.item(item.title, artist: item.artist.isEmpty ? "Placeholder Artist" : item.artist,
                                   source: item.source)
        matched.originalTitle = item.originalTitle
        matched.originalArtist = item.originalArtist
        return matched
    }
}
