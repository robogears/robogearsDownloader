import Foundation
import RobogearsCore

// ─────────────────────────────────────────────────────────────────────────
// TEMPORARY STAND-INS. Everything in this folder is sample behaviour so the
// window can be built and checked before the real TIDAL client, resolver,
// matcher, download pipeline, library scanner and preview player land from
// their own lanes. Each type here conforms to a protocol in
// Services/ServiceProtocols.swift; wiring the real services means replacing
// `StandIn.services()` and `StandInPreviewPlayer` in AppModel.live() and
// deleting this folder.
//
// What they never do: make a network request, read a token, write into the
// download or library folder. Titles and artists are invented.
// ─────────────────────────────────────────────────────────────────────────

enum StandIn {
    static func services() -> AppServices {
        AppServices(resolver: StandInResolver(),
                    library: StandInLibrary(),
                    downloader: StandInDownloader(),
                    previews: StandInPreviews(),
                    signIn: StandInSignIn())
    }

    /// Stable across launches (Swift's `hashValue` isn't): FNV-1a.
    static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    /// A made-up TIDAL id for a title and artist.
    static func tidalID(title: String, artist: String) -> Int64 {
        Int64(hash(title.lowercased() + "\u{1}" + artist.lowercased()) % 900_000_000) + 100_000_000
    }

    /// Track length in seconds, fixed per id so the row and the preview agree.
    static func duration(for tidalID: Int64) -> Int {
        150 + Int(UInt64(tidalID) % 230)
    }

    /// 200 deterministic peaks with an intro, a body and an outro; loudest exactly 1.
    static func peaks(for tidalID: Int64) -> [Float] {
        var state = UInt64(tidalID) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        let count = 200
        let breakdown = 90 + Int(UInt64(tidalID) % 50)
        var values: [Float] = []
        values.reserveCapacity(count)
        var smooth: Float = 0.4
        for i in 0..<count {
            let x = Float(i) / Float(count - 1)
            let intro = min(1, x / 0.12)
            let outro = min(1, (1 - x) / 0.1)
            var level = 0.55 + 0.35 * sinf(x * 9.0 + Float(tidalID % 7))
            if abs(i - breakdown) < 9 { level *= 0.35 }
            smooth = smooth * 0.55 + (level * (0.65 + 0.35 * next())) * 0.45
            values.append(max(0.04, smooth * intro * outro))
        }
        let top = values.max() ?? 1
        return values.map { $0 / top }
    }

    /// A ready queue row for an invented track.
    static func item(_ title: String, version: String? = nil, artist: String = "Placeholder Artist",
                     album: String? = nil, hiRes: Bool = false, explicit: Bool = false,
                     source: QueueItem.Source = .tidal) -> QueueItem {
        let id = tidalID(title: title + (version ?? ""), artist: artist)
        return QueueItem(tidalID: id, title: title, version: version, artist: artist,
                         album: album ?? "Stand-in Sessions", durationSeconds: duration(for: id),
                         hiRes: hiRes, explicit: explicit, source: source)
    }

    /// The invented catalogue links and searches draw from.
    static let catalog: [(title: String, version: String?, artist: String, hiRes: Bool, explicit: Bool)] = [
        ("Blue Lantern", nil, "Placeholder Artist", true, false),
        ("Intro", "Extended Mix", "Placeholder Artist", true, true),
        ("Seven", nil, "The Band", false, false),
        ("Northern Lights", nil, "Coastline", true, false),
        ("Paper Boats", nil, "Coastline", false, false),
        ("Late Ferry", nil, "Harbour Lights", true, false),
        ("Glass Houses", nil, "Placeholder Artist", false, true),
        ("Golden Hour", "Radio Edit", "Sunline", false, false),
        ("Slow Motion", nil, "Placeholder Artist", true, false),
        ("Satellite", nil, "Other Artist", false, false),
        ("Afterglow", nil, "Placeholder Artist", true, false),
        ("Echo Park", nil, "Placeholder Artist", false, false),
        ("Driftwood", nil, "Placeholder Artist", false, false),
        ("Hollow", nil, "New Artist", false, false),
        ("Undertow", nil, "Placeholder Artist", true, false),
        ("Lanterns", nil, "Sample Choir", true, false),
        ("Tidepool", nil, "Coastline", false, false),
        ("Night Bus", "Original Mix", "Placeholder Artist", true, false),
        ("Concrete Garden", nil, "The Band", false, true),
        ("Warm Static", "Dub", "Sunline", true, false),
        ("Halcyon", nil, "Harbour Lights", true, false),
        ("Low Tide", nil, "Coastline", false, false),
        ("Neon Weather", "Extended Mix", "Placeholder Artist", true, false),
        ("Last Train Home", nil, "Sample Choir", false, false),
    ]
}
