import Foundation
import Testing
@testable import RobogearsCore

/// Worked examples are what JavaScript's `encodeURIComponent` returns for
/// the same input, so the Swift app sends what the Electron app sent.
@Suite("Percent-encoding like encodeURIComponent")
struct URIComponentTests {
    @Test func unreservedCharactersStayAsTheyAre() {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
        #expect(URIComponent.encode(unreserved) == unreserved)
    }

    @Test func everyOtherAsciiCharacterIsEscapedWithUppercaseHex() {
        // encodeURIComponent("!#$&'()*+,/:;=?@[]") in JavaScript:
        #expect(URIComponent.encode("!#$&'()*+,/:;=?@[]") == "!%23%24%26'()*%2B%2C%2F%3A%3B%3D%3F%40%5B%5D")
        // encodeURIComponent("\"<>\\^`{|}% ") in JavaScript:
        #expect(URIComponent.encode("\"<>\\^`{|}% ") == "%22%3C%3E%5C%5E%60%7B%7C%7D%25%20")
        #expect(URIComponent.encode("\t\n") == "%09%0A")
    }

    @Test func plusIsSentAsPercent2BSoMumfordAndSonsSurvives() {
        #expect(URIComponent.encode("Mumford + Sons") == "Mumford%20%2B%20Sons")
    }

    @Test func spaceIsPercent20NeverPlus() {
        #expect(URIComponent.encode("Blue Lantern") == "Blue%20Lantern")
    }

    @Test func nonAsciiTextIsEncodedAsUtf8Bytes() {
        #expect(URIComponent.encode("café") == "caf%C3%A9")
        #expect(URIComponent.encode("東京") == "%E6%9D%B1%E4%BA%AC")
        #expect(URIComponent.encode("😀") == "%F0%9F%98%80")
    }

    @Test func decomposedAccentKeepsTheBaseLetterLikeJavaScript() {
        // "e" followed by U+0301 COMBINING ACUTE ACCENT is one Swift Character
        // but two code points; JS encodes them separately.
        #expect(URIComponent.encode("e\u{0301}") == "e%CC%81")
    }

    @Test func oauthScopeTravelsAsOnePlusJoinedToken() {
        let body = URIComponent.formBody([(name: "scope", value: "r_usr+w_usr+w_sub")])
        #expect(body == "scope=r_usr%2Bw_usr%2Bw_sub")
    }

    @Test func formBodyEncodesKeysAndValuesAndKeepsTheirOrder() {
        let body = URIComponent.formBody([
            (name: "client_id", value: "id with space"),
            (name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code"),
            (name: "a b", value: "="),
        ])
        #expect(body == "client_id=id%20with%20space&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&a%20b=%3D")
    }

    @Test func queryLeavesKeysRawAndKeepsOrder() {
        let query = URIComponent.query([
            (name: "query", value: "AC/DC & Friends"),
            (name: "limit", value: "10"),
            (name: "countryCode", value: "US"),
        ])
        #expect(query == "query=AC%2FDC%20%26%20Friends&limit=10&countryCode=US")
    }

    @Test func emptyValuesStayEmpty() {
        #expect(URIComponent.encode("") == "")
        #expect(URIComponent.query([(name: "q", value: "")]) == "q=")
    }
}
