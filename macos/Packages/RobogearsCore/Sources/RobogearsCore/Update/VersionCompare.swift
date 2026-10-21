// Deciding whether a GitHub release is newer than the running app.
//
// A port of the Electron `isNewerVersion` (`electron-main.js:103-113`;
// packaging-ci-and-updater.md, "Updater: main process" item 10): strip one
// leading lowercase "v", split on dots, read each part's leading number the
// way JavaScript's parseInt does (anything unreadable is 0), and treat missing
// parts as 0, so "0.2" equals "0.2.0". Equal is not newer.
//
// One deliberate change: a pre-release ("0.1.31-rc1") is older than the same
// release, and pre-releases compare by their identifiers as semantic
// versioning orders them. The Electron code read "0.1.31-rc1" as 0.1.31, and
// "0.1.31-rc.1" as 0.1.31.1, newer than 0.1.31 itself.

public struct VersionNumber: Sendable, Comparable, CustomStringConvertible {
    /// The dot-separated numbers before any "-" or "+".
    public let numbers: [Int]
    /// The pre-release identifiers after "-" (empty for a release).
    public let preRelease: [String]

    public init(_ string: String) {
        var text = Substring(string)
        if text.first == "v" { text = text.dropFirst() }
        // Build metadata ("+build5") never affects order.
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
        // The first "-" after the start begins a pre-release. A leading "-"
        // stays part of the first number, as parseInt reads it.
        var core = text
        var pre: Substring = ""
        if let dash = text.dropFirst().firstIndex(of: "-") {
            core = text[..<dash]
            pre = text[text.index(after: dash)...]
        }
        numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Self.parseIntLikeJavaScript($0) ?? 0 }
        preRelease = pre.isEmpty ? [] : pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (preRelease.isEmpty ? "" : "-" + preRelease.joined(separator: "."))
    }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        compare(lhs, rhs) < 0
    }

    /// Equal when the numbers match with missing parts as 0 and the
    /// pre-release identifiers match ("0.2" == "0.2.0").
    public static func == (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        compare(lhs, rhs) == 0
    }

    private static func compare(_ a: VersionNumber, _ b: VersionNumber) -> Int {
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        switch (a.preRelease.isEmpty, b.preRelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1   // a release is newer than its pre-releases
        case (false, true): return -1
        case (false, false): return comparePreRelease(a.preRelease, b.preRelease)
        }
    }

    /// Semantic Versioning 2.0.0 §11: identifier by identifier; numeric ones
    /// compare as numbers and sort before words; a longer list wins a tie.
    private static func comparePreRelease(_ a: [String], _ b: [String]) -> Int {
        for (x, y) in zip(a, b) where x != y {
            let xNumber = isDigits(x) ? Int(x) : nil
            let yNumber = isDigits(y) ? Int(y) : nil
            switch (xNumber, yNumber) {
            case let (x?, y?): if x != y { return x < y ? -1 : 1 }
            case (.some, nil): return -1
            case (nil, .some): return 1
            case (nil, nil): return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8)) ? -1 : 1
            }
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    private static func isDigits(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// JavaScript's `parseInt(s, 10)`: skips leading whitespace, takes an
    /// optional sign and the digits that follow, and gives up (NaN, here nil)
    /// when there are none. Values too large for Int are clamped.
    static func parseIntLikeJavaScript(_ s: Substring) -> Int? {
        var scalars = s.unicodeScalars.drop(while: { FileNaming.javaScriptWhitespace.contains($0.value) })
        var negative = false
        if let sign = scalars.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            scalars = scalars.dropFirst()
        }
        var value = 0
        var sawDigit = false
        for scalar in scalars {
            guard scalar.value >= 0x30, scalar.value <= 0x39 else { break }
            sawDigit = true
            let digit = Int(scalar.value - 0x30)
            let (times, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times.addingReportingOverflow(digit)
            value = (overflow1 || overflow2) ? Int.max : sum
        }
        guard sawDigit else { return nil }
        return negative ? -value : value
    }
}

public enum VersionCompare {
    /// Whether `remote` (a release tag such as "v0.1.32") is newer than
    /// `current` (the running app's version). Equal is not newer.
    public static func isNewer(_ remote: String, than current: String) -> Bool {
        VersionNumber(remote) > VersionNumber(current)
    }
}
