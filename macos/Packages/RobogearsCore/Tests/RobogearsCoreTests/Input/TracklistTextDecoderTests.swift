import Foundation
import Testing
@testable import RobogearsCore

// Decision card G4-15: byte-order mark, then strict UTF-8, then Windows-1252.

@Suite("Tracklist files: decoding")
struct TracklistTextDecoderTests {
    @Test func plainUTF8IsReadAsIs() {
        let decoded = TracklistTextDecoder.decode(Data("Café Lumière - Northbound Choir\n".utf8))
        #expect(decoded.text == "Café Lumière - Northbound Choir\n")
        #expect(decoded.encoding == .utf8)
        #expect(!decoded.hadByteOrderMark)
    }

    @Test func utf8ByteOrderMarkIsRemoved() {
        let decoded = TracklistTextDecoder.decode(Data([0xEF, 0xBB, 0xBF] + Array("Title,Artist".utf8)))
        #expect(decoded.text.unicodeScalars.first == "T")
        #expect(decoded.encoding == .utf8)
        #expect(decoded.hadByteOrderMark)
    }

    @Test func musicAppExportInUTF16LittleEndianIsReadable() throws {
        // The Electron app read this as UTF-8: a NUL after every letter.
        let decoded = TracklistTextDecoder.decode(try InputLaneFixtures.data("music-app-export.txt"))
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(decoded.hadByteOrderMark)
        #expect(decoded.text.hasPrefix("Name\tArtist\t"))
        #expect(decoded.text.contains("夜の灯台"))
        #expect(!decoded.text.unicodeScalars.contains("\u{0}"))
        #expect(!decoded.looksBinary)
    }

    @Test func utf16BigEndianWithByteOrderMarkIsReadable() {
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in "Blue Lantern\tPlaceholder Artist".utf16 { bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        let decoded = TracklistTextDecoder.decode(Data(bytes))
        #expect(decoded.encoding == .utf16BigEndian)
        #expect(decoded.text == "Blue Lantern\tPlaceholder Artist")
    }

    @Test func utf16WithoutByteOrderMarkIsRecognisedByItsNULs() {
        var bytes: [UInt8] = []
        for unit in "Name\tArtist\rBlue Lantern\tPlaceholder Artist\r".utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        let decoded = TracklistTextDecoder.decode(Data(bytes))
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(!decoded.hadByteOrderMark)
        #expect(decoded.text == "Name\tArtist\rBlue Lantern\tPlaceholder Artist\r")
    }

    @Test func windows1252CSVKeepsItsAccents() throws {
        // "Café" used to become "Caf\u{FFFD}".
        let decoded = TracklistTextDecoder.decode(try InputLaneFixtures.data("excel-semicolon-windows1252.csv"))
        #expect(decoded.encoding == .windows1252)
        #expect(decoded.text.contains("Café Lumière"))
        #expect(decoded.text.contains("Blue Lantern \u{2013} Live"))
        #expect(!decoded.text.contains("\u{FFFD}"))
    }

    @Test func windows1252HighBytesFollowTheBrowserTable() {
        let text = TracklistTextDecoder.decodeWindows1252([0x80, 0x93, 0x94, 0x96, 0x97, 0x81, 0xE9])
        #expect(Array(text.unicodeScalars.map(\.value)) == [0x20AC, 0x201C, 0x201D, 0x2013, 0x2014, 0x81, 0xE9])
    }

    @Test func invalidUTF8FallsBackToWindows1252InsteadOfReplacementCharacters() {
        let decoded = TracklistTextDecoder.decode(Data([0x43, 0x61, 0x66, 0xE9]))
        #expect(decoded.encoding == .windows1252)
        #expect(decoded.text == "Café")
    }

    @Test func audioLikeBytesLookBinary() {
        // An ID3 header followed by frame bytes with NULs, as in an MP3.
        var bytes: [UInt8] = Array("ID3".utf8) + [0x04, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x76]
        for i in 0..<2048 { bytes.append(UInt8((i * 37) & 0xFF)) }
        #expect(TracklistTextDecoder.decode(Data(bytes)).looksBinary)
    }

    @Test func ordinaryListsDontLookBinary() throws {
        for name in ["exportify-classic.csv", "exportify-current.csv", "excel-semicolon-windows1252.csv", "pasted-list.txt", "web-table-rows.txt"] {
            #expect(!TracklistTextDecoder.decode(try InputLaneFixtures.data(name)).looksBinary, "\(name)")
        }
    }

    @Test func emptyFileDecodesToEmptyText() {
        let decoded = TracklistTextDecoder.decode(Data())
        #expect(decoded.text.isEmpty)
        #expect(!decoded.looksBinary)
    }
}
