import Foundation

/// Reads TIDAL's MPEG-DASH manifests (`application/dash+xml`).
///
/// The Electron app read the MPD with regular expressions
/// (download-pipeline.md B7, main-process-and-ipc.md section 12). This uses
/// `XMLParser` instead, which unescapes `&amp;` and friends in every value
/// (the Electron download parser forgot to in its direct branch, bug 12),
/// accepts `<S>` written with or without a closing tag, and lets the segment
/// count come from the first `SegmentTemplate` only, not from every `<S>` in
/// the document. The rules stay the same: `startNumber` defaults to 1, each
/// `<S r="N"/>` stands for N + 1 segments, and `$Number$` is filled in.
enum DASHManifestReader {
    /// No real track comes near this (a ten-hour mix in four-second segments
    /// is 9,000); anything above it is a broken manifest, not music.
    static let segmentLimit = 50_000

    static func read(_ data: Data) throws(TIDALManifestError)
        -> (format: TIDALManifest.Format, location: TIDALManifest.Location, mimeType: String?, codecs: String?) {
        let collector = DASHCollector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        guard parser.parse(), !collector.failed else { throw .unreadableManifest }
        let mpd = collector.document

        if mpd.isProtected { throw .copyProtected("ContentProtection") }

        // A BaseURL with no SegmentTemplate is one plain file
        // (download-pipeline.md B7 step 4, "direct").
        guard mpd.hasSegmentTemplate else {
            guard let base = mpd.baseURL, !base.isEmpty else { throw .missingSegmentTemplate }
            return (.dash, .direct(try TIDALManifest.streamURL(base)), mpd.mimeType, mpd.codecs)
        }
        guard let initialization = mpd.initialization, let media = mpd.media else {
            throw .missingSegmentTemplate
        }

        let numbers = try segmentNumbers(startNumber: mpd.startNumber, repeats: mpd.repeats)
        let initURL = try url(base: mpd.baseURL, template: expand(initialization, number: nil))
        var mediaURLs: [URL] = []
        mediaURLs.reserveCapacity(numbers.count)
        for number in numbers {
            mediaURLs.append(try url(base: mpd.baseURL, template: expand(media, number: number)))
        }
        return (.dash, .segments(initialization: initURL, media: mediaURLs), mpd.mimeType, mpd.codecs)
    }

    /// The segment numbers in order: from `startNumber` (1 when absent), each
    /// timeline entry adding `r + 1` numbers. `d` and `t` don't affect
    /// `$Number$` addressing and are ignored, as before.
    static func segmentNumbers(startNumber: String?, repeats: [String?]) throws(TIDALManifestError) -> [Int] {
        var next = 1
        if let raw = startNumber {
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)),
                  value >= 0, value <= 1_000_000_000 else { throw .unreadableManifest }
            next = value
        }
        var numbers: [Int] = []
        for raw in repeats {
            var repeatCount = 0
            if let raw {
                guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { throw .unreadableManifest }
                repeatCount = value
            }
            if repeatCount < 0 { throw .openEndedTimeline }
            guard repeatCount < segmentLimit, numbers.count + repeatCount + 1 <= segmentLimit else {
                throw .tooManySegments
            }
            for _ in 0...repeatCount {
                numbers.append(next)
                next += 1
            }
        }
        guard !numbers.isEmpty else { throw .noSegments }
        return numbers
    }

    /// Fills in a segment template. Supports `$Number$`, the padded form
    /// `$Number%05d$` and the escaped dollar `$$`. Any other placeholder
    /// (`$Time$`, `$RepresentationID$`, `$Bandwidth$`) throws instead of being
    /// sent to TIDAL literally. A lone `$` with no partner is kept as written.
    static func expand(_ template: String, number: Int?) throws(TIDALManifestError) -> String {
        guard template.contains("$") else { return template }
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "$") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "$") else {
                result += rest[open...]
                return result
            }
            let identifier = String(rest[afterOpen..<close])
            if identifier.isEmpty {
                result += "$"
            } else if identifier == "Number" {
                guard let number else { throw .unsupportedTemplate("$Number$") }
                result += String(number)
            } else if let width = paddedNumberWidth(identifier) {
                guard let number else { throw .unsupportedTemplate("$\(identifier)$") }
                let digits = String(number)
                result += String(repeating: "0", count: max(0, width - digits.count)) + digits
            } else {
                throw .unsupportedTemplate("$\(identifier)$")
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    /// The width in `Number%0<width>d`, the only format tag DASH allows.
    private static func paddedNumberWidth(_ identifier: String) -> Int? {
        guard identifier.hasPrefix("Number%0"), identifier.hasSuffix("d") else { return nil }
        let digits = identifier.dropFirst("Number%0".count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let width = Int(digits), width <= 20 else { return nil }
        return width
    }

    /// An absolute template is used as it is; a relative one is appended to
    /// the BaseURL, the plain joining the Electron code did.
    private static func url(base: String?, template: String) throws(TIDALManifestError) -> URL {
        let lowered = template.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return try TIDALManifest.streamURL(template)
        }
        return try TIDALManifest.streamURL((base ?? "") + template)
    }
}

/// Collects the few things the reader needs from an MPD in one pass.
private final class DASHCollector: NSObject, XMLParserDelegate {
    struct Document {
        /// The first `<BaseURL>` text, trimmed and unescaped.
        var baseURL: String?
        var hasSegmentTemplate = false
        var initialization: String?
        var media: String?
        var startNumber: String?
        /// The `r` of every `<S>` inside the first SegmentTemplate, in order.
        var repeats: [String?] = []
        /// The first `mimeType` and `codecs` attributes in document order,
        /// wherever they sit (AdaptationSet or Representation), as before.
        var mimeType: String?
        var codecs: String?
        var isProtected = false
    }

    private(set) var document = Document()
    private(set) var failed = false
    private var collectingBaseURL = false
    private var baseURLText = ""
    private var inFirstTemplate = false

    /// Element names without a namespace prefix (`cenc:pssh` → `pssh`).
    private func localName(_ name: String) -> Substring {
        name.split(separator: ":").last ?? Substring(name)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        if document.mimeType == nil { document.mimeType = nonEmpty(attributeDict["mimeType"]) }
        if document.codecs == nil { document.codecs = nonEmpty(attributeDict["codecs"]) }

        switch localName(elementName) {
        case "ContentProtection":
            document.isProtected = true
        case "BaseURL":
            if document.baseURL == nil && !collectingBaseURL {
                collectingBaseURL = true
                baseURLText = ""
            }
        case "SegmentTemplate":
            if !document.hasSegmentTemplate {
                document.hasSegmentTemplate = true
                inFirstTemplate = true
                document.initialization = nonEmpty(attributeDict["initialization"])
                document.media = nonEmpty(attributeDict["media"])
                document.startNumber = attributeDict["startNumber"]
            }
        case "S":
            if inFirstTemplate { document.repeats.append(attributeDict["r"]) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingBaseURL { baseURLText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if collectingBaseURL { baseURLText += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "BaseURL":
            if collectingBaseURL {
                document.baseURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                collectingBaseURL = false
            }
        case "SegmentTemplate":
            inFirstTemplate = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failed = true
    }
}
