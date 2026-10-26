import Foundation

/// Percent-encoding that matches JavaScript's `encodeURIComponent`, used for
/// every TIDAL query value and form body.
///
/// Why not `URLQueryItem`: it leaves `+` unescaped, which servers read as a
/// space. That would turn a search for "Mumford + Sons" into "Mumford   Sons"
/// and change the OAuth scope `r_usr+w_usr+w_sub` that TIDAL receives today
/// as `r_usr%2Bw_usr%2Bw_sub` (reference: tidal-sign-in-and-tokens.md,
/// component 4 and bug 18; tidal-and-spotify-networking.md porting notes).
public enum URIComponent {
    /// The characters `encodeURIComponent` leaves alone: `A-Z a-z 0-9` and
    /// `- _ . ! ~ * ' ( )`. Everything else is sent as UTF-8 `%XX`.
    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
             UInt8(ascii: "!"), UInt8(ascii: "~"), UInt8(ascii: "*"),
             UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
            return true
        default:
            return false
        }
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Encodes `value` exactly as JavaScript's `encodeURIComponent` does:
    /// unreserved ASCII stays, every other UTF-8 byte becomes `%XX` with
    /// uppercase hex. Working on UTF-8 bytes (not `Character`s) keeps a
    /// decomposed accent such as `e` + U+0301 as `e%CC%81`, like JS.
    public static func encode(_ value: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isUnreserved(byte) {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A form body as the Electron `formEncode` builds it: keys and values
    /// both encoded, pairs joined with `&` in the order given. Order matters
    /// only for byte parity with today's requests, which is what the TIDAL
    /// spike will compare against.
    public static func formBody(_ fields: [(name: String, value: String)]) -> String {
        fields
            .map { encode($0.name) + "=" + encode($0.value) }
            .joined(separator: "&")
    }

    /// A query string as `tidalGet` builds it: keys raw, values encoded, order
    /// kept. Keys are fixed ASCII names chosen by this app, so leaving them
    /// raw changes nothing on the wire and mirrors today exactly.
    public static func query(_ parameters: [(name: String, value: String)]) -> String {
        parameters
            .map { $0.name + "=" + encode($0.value) }
            .joined(separator: "&")
    }
}
