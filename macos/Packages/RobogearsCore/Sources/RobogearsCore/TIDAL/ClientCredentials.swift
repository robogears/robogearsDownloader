import Foundation

/// One TIDAL OAuth client pair (an id and a secret that identify an app, not
/// a person).
///
/// The values never leave this type in readable form: `description`,
/// `debugDescription` and the reflection mirror show only the label, so
/// string interpolation, `print`, `dump` and error messages can't leak them
/// by accident. Only the request builders read `clientID` and the Basic
/// header (both internal).
public struct ClientPair: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A short, versioned name stored with a sign-in instead of the secret
    /// (G1-7 skeptic note 2). If a future version swaps the built-in keys, it
    /// gives the new pair a new label; a stored sign-in whose label is
    /// unknown then asks for a fresh sign-in instead of failing renewals.
    public let label: String
    let clientID: String
    let clientSecret: String

    init(label: String, clientID: String, clientSecret: String) {
        self.label = label
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// `Basic base64(utf8("<id>:<secret>"))`, as `Buffer.from(id + ':' +
    /// secret).toString('base64')` builds it today. The secret is used
    /// exactly as decoded; its literal percent escape is never URL-decoded.
    var basicAuthorization: String {
        "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
    }

    public var description: String { "ClientPair(\(label))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["label": label]) }
}

/// The two built-in TIDAL client pairs and their roles (decision G1-7: keep
/// both pairs and the exact request shape until the TIDAL spike says
/// otherwise).
///
/// - `signIn` (the Electron AUTH pair) is used only for the device-code
///   request and the polls that follow.
/// - `renewal` (the Electron REQUEST pair) is what `token.json` stored with
///   every sign-in and what every refresh used. The Swift app stores only its
///   label with the sign-in and looks the pair up when renewing.
///
/// Tokens issued to one pair and renewed with the other "evidently works
/// today but was never checked on its own" (G1-7); if the spike shows it
/// doesn't, renewal switches to `signIn` here, in one place.
public struct ClientKeySet: Sendable {
    public let signIn: ClientPair
    public let renewal: ClientPair

    init(signIn: ClientPair, renewal: ClientPair) {
        self.signIn = signIn
        self.renewal = renewal
    }

    /// The pair a stored sign-in renews with, by its label. Nil means the
    /// sign-in came from keys this version no longer carries.
    func pair(labeled label: String) -> ClientPair? {
        [renewal, signIn].first { $0.label == label }
    }

    /// The keys shipped in the app: the four base64 literals from
    /// `tidal_auth_node.js` lines 17-20, verbatim, decoded at run time as
    /// ISO Latin-1 like `Buffer.from(…, 'base64').toString('latin1')`.
    /// Base64 hides nothing (anyone with the app can read them); it is kept
    /// only so the source matches the reference. Their provenance and where
    /// to find replacements are in CLAUDE.md ("Hardcoded TIDAL client
    /// credentials").
    public static let builtIn = ClientKeySet(
        signIn: ClientPair(
            label: "tidal-signin-1",
            clientID: decodeLatin1(BuiltInLiterals.signInID),
            clientSecret: decodeLatin1(BuiltInLiterals.signInSecret)
        ),
        renewal: ClientPair(
            label: "tidal-renewal-1",
            clientID: decodeLatin1(BuiltInLiterals.renewalID),
            clientSecret: decodeLatin1(BuiltInLiterals.renewalSecret)
        )
    )

    static func decodeLatin1(_ base64: String) -> String {
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .isoLatin1) else {
            // A broken literal is a build mistake; the message names no value.
            preconditionFailure("A built-in TIDAL client literal is not valid base64.")
        }
        return text
    }
}

/// The literals themselves, in the order `tidal_auth_node.js` declares them:
/// AUTH id, AUTH secret, REQUEST id, REQUEST secret.
private enum BuiltInLiterals {
    static let signInID = "ZlgySnhkbW50WldLMGl4VA=="
    static let signInSecret = "MU5tNUFmREFqeHJnSkZKYktOV0xlQXlLR1ZHbUlOdVhQUExIVlhBdnhBZz0="
    static let renewalID = "bHczdlI2R0UxdnROQnNqdg=="
    static let renewalSecret = "WTh0SXBxS0p4czlCRUl3WXIwSTliU2JNV0Rzb2dYSng5TGFOM21DSHdENCUzRA=="
}
