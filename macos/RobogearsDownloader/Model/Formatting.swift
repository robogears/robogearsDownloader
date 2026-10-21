import Foundation

/// Small text helpers shared by rows, the log and VoiceOver.
enum Formatting {
    /// "3:58"; nil when the length is unknown (then nothing is shown).
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "3 minutes 58 seconds", for VoiceOver.
    static func spokenDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: max(0, seconds.rounded())) ?? ""
    }

    /// "1,240" with the person's thousands separator.
    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// "1 track" / "12 tracks".
    static func tracks(_ n: Int) -> String {
        n == 1 ? "1 track" : "\(count(n)) tracks"
    }

    /// "~/Music/TIDAL" for paths in the home folder.
    static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
