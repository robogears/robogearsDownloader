import Foundation
@testable import RobogearsCore

/// Loads files from Fixtures/input.
enum InputLaneFixtures {
    static func data(_ name: String) throws -> Data {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/input") else {
            throw FixtureMissing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func parsed(_ name: String) throws -> ParsedTracklist {
        TracklistParser.parse(TracklistTextDecoder.decode(try data(name)).text)
    }

    struct FixtureMissing: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixtures/input/\(name) is missing from the test bundle" }
    }
}

extension ParsedTracklist.Reading {
    /// Shorthand for expectations: `.init("Blue Lantern", "Placeholder Artist")`.
    init(_ title: String, _ artist: String) {
        self.init(title: title, artist: artist)
    }
}
