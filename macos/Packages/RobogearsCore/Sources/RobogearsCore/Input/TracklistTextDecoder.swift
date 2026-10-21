// Turns the bytes of a dropped or opened tracklist file into text.
//
// The Electron app decoded every file as UTF-8, so Music's playlist export
// (UTF-16) and Excel's Windows-encoded CSVs came out as garbage (decision card
// G4-15; text-unicode-and-filenames.md §6). The order here is the card's, with
// the skeptic's correction: byte-order mark first, then strict UTF-8, then
// Windows Latin (Windows-1252).

import Foundation

public enum TracklistTextDecoder {
    public enum Encoding: String, Sendable, Hashable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        case windows1252
    }

    public struct Decoded: Sendable, Hashable {
        /// The text, with any leading byte-order mark removed.
        public let text: String
        public let encoding: Encoding
        /// Whether the file started with a byte-order mark.
        public let hadByteOrderMark: Bool

        /// Whether the text looks like binary data rather than a tracklist (an
        /// audio file or image dropped by mistake). The Electron app read such
        /// files as thousands of junk "tracks" (G4-8).
        public var looksBinary: Bool { TracklistTextDecoder.looksBinary(text) }
    }

    public static func decode(_ data: Data) -> Decoded {
        let bytes = [UInt8](data)

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return Decoded(text: decodeUTF8Lossy(bytes.dropFirst(3)), encoding: .utf8, hadByteOrderMark: true)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return Decoded(text: decodeUTF16(bytes.dropFirst(2), littleEndian: true), encoding: .utf16LittleEndian, hadByteOrderMark: true)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return Decoded(text: decodeUTF16(bytes.dropFirst(2), littleEndian: false), encoding: .utf16BigEndian, hadByteOrderMark: true)
        }
        // UTF-16 without a byte-order mark is valid UTF-8 (every other byte is
        // a NUL), so it has to be recognised before the UTF-8 attempt.
        if let littleEndian = bomlessUTF16ByteOrder(bytes) {
            return Decoded(
                text: decodeUTF16(bytes[...], littleEndian: littleEndian),
                encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian,
                hadByteOrderMark: false
            )
        }
        if let text = String(validating: bytes, as: UTF8.self) {
            return Decoded(text: text, encoding: .utf8, hadByteOrderMark: false)
        }
        return Decoded(text: decodeWindows1252(bytes), encoding: .windows1252, hadByteOrderMark: false)
    }

    // MARK: - Decoders

    private static func decodeUTF8Lossy(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Unpaired surrogates become U+FFFD; an odd trailing byte is dropped.
    private static func decodeUTF16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(littleEndian ? (second << 8 | first) : (first << 8 | second))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Windows-1252 as browsers decode it (the WHATWG table): 0x80–0x9F carry
    /// curly quotes, dashes and the euro sign; the five undefined bytes map to
    /// the C1 control with the same number; every other byte is Latin-1.
    /// Written out here because Foundation's converter refuses the undefined
    /// bytes and would fail the whole file.
    static func decodeWindows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            let value: UInt32
            if byte >= 0x80 && byte <= 0x9F {
                value = windows1252High[Int(byte - 0x80)]
            } else {
                value = UInt32(byte)
            }
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    private static let windows1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    // MARK: - Heuristics

    /// Recognises UTF-16 without a byte-order mark: in plain Latin text every
    /// other byte is NUL and the rest are printable ASCII. Returns true for
    /// little-endian, false for big-endian, nil when it isn't UTF-16.
    private static func bomlessUTF16ByteOrder(_ bytes: [UInt8]) -> Bool? {
        let sample = bytes.prefix(4096)
        guard sample.count >= 4 else { return nil }
        var evenNUL = 0, oddNUL = 0, evenText = 0, oddText = 0
        for (offset, byte) in sample.enumerated() {
            let printable = byte == 0x09 || byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte < 0x7F)
            if offset.isMultiple(of: 2) {
                if byte == 0 { evenNUL += 1 } else if printable { evenText += 1 }
            } else {
                if byte == 0 { oddNUL += 1 } else if printable { oddText += 1 }
            }
        }
        let half = sample.count / 2
        // Little-endian ASCII: text bytes at even offsets, NULs at odd ones.
        if oddNUL * 10 >= half * 7, evenText * 10 >= half * 8 { return true }
        if evenNUL * 10 >= half * 7, oddText * 10 >= half * 8 { return false }
        return nil
    }

    /// Binary data shows up as NULs or as many control characters that never
    /// appear in text files (anything below U+0020 except tab, line feed,
    /// vertical tab, form feed and carriage return).
    static func looksBinary(_ text: String) -> Bool {
        var total = 0, controls = 0
        for scalar in text.unicodeScalars.prefix(65_536) {
            total += 1
            if scalar.value == 0 { return true }
            if scalar.value < 0x20, ![0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(scalar.value) {
                controls += 1
            }
        }
        guard total > 0 else { return false }
        return controls * 100 > total
    }
}
