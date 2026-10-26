import Foundation
import Testing
@testable import RobogearsCore

/// The built-in client pairs (decision G1-7). These tests never print a
/// value: every check on a secret is reduced to a Bool first, so a failing
/// `#expect` can't show the secret in its message.
@Suite("Built-in TIDAL client keys")
struct ClientCredentialsTests {
    @Test func builtInPairsDecodeToThePlainAsciiLengthsOfTheReference() {
        let keys = ClientKeySet.builtIn
        // Lengths of the decoded Electron literals (tidal_auth_node.js:17-20).
        let lengths = [keys.signIn.clientID.utf8.count, keys.signIn.clientSecret.utf8.count,
                       keys.renewal.clientID.utf8.count, keys.renewal.clientSecret.utf8.count]
        #expect(lengths == [16, 44, 16, 46])
        let allASCII = [keys.signIn.clientID, keys.signIn.clientSecret, keys.renewal.clientID, keys.renewal.clientSecret]
            .allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) }
        #expect(allASCII)
    }

    @Test func renewalSecretKeepsItsLiteralPercentEscape() {
        let secret = ClientKeySet.builtIn.renewal.clientSecret
        let keepsPercent = secret.contains("%")
        let wouldChangeIfDecoded = secret.removingPercentEncoding != secret
        #expect(keepsPercent)
        #expect(wouldChangeIfDecoded)
    }

    @Test func signInAndRenewalPairsStayDistinct() {
        let keys = ClientKeySet.builtIn
        let distinct = keys.signIn.clientID != keys.renewal.clientID && keys.signIn.label != keys.renewal.label
        #expect(distinct)
    }

    @Test func basicHeaderIsBase64OfIdColonSecretUsedVerbatim() {
        let pair = ClientPair(label: "x", clientID: "renewal-id", clientSecret: "abc%2Fdef")
        #expect(pair.basicAuthorization == "Basic " + Data("renewal-id:abc%2Fdef".utf8).base64EncodedString())
    }

    @Test func printingAPairShowsOnlyItsLabel() {
        let pair = ClientKeySet.builtIn.renewal
        var dumped = ""
        dump(pair, to: &dumped)
        let texts = [String(describing: pair), String(reflecting: pair), "\(pair)", dumped]
        let leaks = texts.contains { $0.contains(pair.clientSecret) || $0.contains(pair.clientID) }
        #expect(!leaks)
        #expect(String(describing: pair) == "ClientPair(tidal-renewal-1)")
    }

    @Test func storedSignInLooksUpItsPairByLabel() {
        let keys = TIDALClientFixtures.keys
        #expect(keys.pair(labeled: "test-renewal")?.label == "test-renewal")
        #expect(keys.pair(labeled: "test-signin")?.label == "test-signin")
        #expect(keys.pair(labeled: "keys-from-an-older-version") == nil)
    }
}
