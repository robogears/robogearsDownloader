import Foundation

/// Where a track's audio lives, read from the base64 manifest in TIDAL's
/// playback reply. One parser now serves both downloads and previews; the
/// Electron app had two copies that already disagreed on unescaping
/// (download-pipeline.md B7 and bug 12, main-process-and-ipc.md section 12).
public struct TIDALManifest: Sendable, Hashable, CustomStringConvertible {
    /// Which manifest family TIDAL sent.
    public enum Format: String, Sendable, Hashable {
        /// `application/vnd.tidal.bt`, `.bts` or any later `vnd.tidal.*`
        /// variant: JSON with one direct URL.
        case bts
        /// `application/dash+xml`: an MPEG-DASH MPD.
        case dash
    }

    /// How to fetch the audio.
    public enum Location: Sendable, Hashable {
        /// One file at one URL.
        case direct(URL)
        /// An initialization segment, then every media segment in order.
        /// Joined together they form one fragmented MP4.
        case segments(initialization: URL, media: [URL])
    }

    /// What the fetched bytes will be once joined.
    public enum Container: String, Sendable, Hashable {
        /// A plain FLAC file.
        case flac
        /// An MP4: FLAC or AAC inside fragmented MP4 for DASH segments, or an
        /// AAC `.m4a` direct file.
        case mp4

        /// The extension for the temporary download, as the Electron
        /// downloader chose it (`.tmp.m4a` or `.tmp.flac`, download-pipeline.md B5 step 15).
        public var fileExtension: String {
            switch self {
            case .flac: "flac"
            case .mp4: "m4a"
            }
        }

        /// The MIME type to give a player for the preview.
        public var mimeType: String {
            switch self {
            case .flac: "audio/flac"
            case .mp4: "audio/mp4"
            }
        }
    }

    public let format: Format
    public let location: Location
    /// The MIME type the manifest declares, if any.
    public let mimeType: String?
    /// The codecs the manifest declares, for example `flac` or `mp4a.40.2`.
    public let codecs: String?
    /// Whether the saved file is `.flac` rather than the `.m4a` AAC fallback.
    public let isFLAC: Bool

    /// Segments always join into a fragmented MP4 (the Electron preview
    /// labelled them `audio/mp4`). A BTS direct file is an MP4 when its JSON
    /// says so and FLAC otherwise, as both Electron paths defaulted to FLAC.
    /// A DASH manifest with only a `BaseURL` is FLAC whatever the MPD's
    /// attributes say: both Electron parsers hard-coded `audio/flac` there
    /// (download-pipeline.md B7 step 4, main-process-and-ipc.md section 12
    /// step 5), and no decision card changes it.
    public var container: Container {
        switch location {
        case .segments:
            return .mp4
        case .direct where format == .dash:
            return .flac
        case .direct:
            return (mimeType?.lowercased().contains("mp4") ?? false) ? .mp4 : .flac
        }
    }

    /// The number of separate requests the audio needs.
    public var requestCount: Int {
        switch location {
        case .direct: 1
        case .segments(_, let media): media.count + 1
        }
    }

    /// Never prints a URL: these are signed links that grant access to the
    /// file and must not reach a log or the screen (G5-16).
    public var description: String {
        "TIDALManifest(\(format.rawValue), \(location), codecs: \(codecs ?? "nil"), "
            + "mimeType: \(mimeType ?? "nil"), flac: \(isFLAC))"
    }

    public init(format: Format, location: Location, mimeType: String?, codecs: String?, isFLAC: Bool) {
        self.format = format
        self.location = location
        self.mimeType = mimeType
        self.codecs = codecs
        self.isFLAC = isFLAC
    }

    /// Reads the manifest in a playback reply.
    public init(playbackInfo: TIDALPlaybackInfo) throws(TIDALManifestError) {
        try self.init(
            manifestMimeType: playbackInfo.manifestMimeType,
            base64Manifest: playbackInfo.manifest,
            audioQuality: playbackInfo.audioQuality
        )
    }

    /// Reads a base64 manifest of the given type. `audioQuality` is the tier
    /// TIDAL says it delivered; it decides FLAC before the codec does.
    public init(manifestMimeType: String?, base64Manifest: String?, audioQuality: String?) throws(TIDALManifestError) {
        guard let base64Manifest, !base64Manifest.isEmpty else { throw .missingManifest }
        guard let data = Self.decodeBase64(base64Manifest) else { throw .unreadableEncoding }
        let text = String(decoding: data, as: UTF8.self)

        let type = Self.normalizedType(manifestMimeType)
        let parsed: (format: Format, location: Location, mimeType: String?, codecs: String?)
        if type.hasPrefix("application/vnd.tidal.") {
            parsed = try Self.parseBTS(data)
        } else if type == "application/dash+xml" {
            parsed = try DASHManifestReader.read(data)
        } else {
            throw .unsupportedType(manifestMimeType)
        }

        self.init(
            format: parsed.format,
            location: parsed.location,
            mimeType: parsed.mimeType,
            codecs: parsed.codecs,
            isFLAC: Self.isFLAC(audioQuality: audioQuality, codecs: parsed.codecs, manifestText: text)
        )
    }

    /// The FLAC-or-AAC rule, in the Electron downloader's order
    /// (download-pipeline.md B5 step 12): TIDAL's own tier label first, then
    /// the declared codec, then `codecs="flac"` anywhere in the manifest text.
    public static func isFLAC(audioQuality: String?, codecs: String?, manifestText: String) -> Bool {
        if TIDALAudioQuality.isLosslessTier(audioQuality) { return true }
        if let codecs, codecs.lowercased().contains("flac") { return true }
        return manifestText.range(of: #"codecs="flac""#, options: .caseInsensitive) != nil
    }

    // MARK: - Pieces

    /// The MIME type without parameters, lowercased, so `Application/DASH+XML;
    /// charset=utf-8` still counts as DASH.
    private static func normalizedType(_ type: String?) -> String {
        guard let type else { return "" }
        let bare = type.split(separator: ";", maxSplits: 1).first.map(String.init) ?? type
        return bare.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Decodes base64 as forgivingly as Node's `Buffer.from(_, 'base64')`:
    /// whitespace ignored, URL-safe letters accepted, padding optional.
    static func decodeBase64(_ text: String) -> Data? {
        var cleaned = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        ))
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while cleaned.hasSuffix("=") { cleaned.removeLast() }
        switch cleaned.count % 4 {
        case 1: cleaned.removeLast()   // a lone trailing character carries no whole byte
        case 2: cleaned += "=="
        case 3: cleaned += "="
        default: break
        }
        guard !cleaned.isEmpty else { return nil }
        return Data(base64Encoded: cleaned)
    }

    /// The BT/BTS JSON manifest: `{ mimeType, codecs, encryptionType, urls }`.
    private static func parseBTS(_ data: Data) throws(TIDALManifestError)
        -> (format: Format, location: Location, mimeType: String?, codecs: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .unreadableManifest
        }
        // Anything set other than NONE is copy protection, as in Electron
        // (`encryptionType && encryptionType !== 'NONE'`).
        if let encryption = object["encryptionType"], isPresent(encryption) {
            let label = (encryption as? String) ?? String(describing: encryption)
            if label.uppercased() != "NONE" { throw .copyProtected(label) }
        }
        guard let urls = object["urls"] as? [Any], let first = urls.first as? String else {
            throw .noStreamURL
        }
        let url = try streamURL(first)
        return (.bts, .direct(url), object["mimeType"] as? String, object["codecs"] as? String)
    }

    /// JavaScript truthiness for a JSON value: null, false, 0 and "" are absent.
    private static func isPresent(_ value: Any) -> Bool {
        switch value {
        case is NSNull: return false
        case let text as String: return !text.isEmpty
        case let number as NSNumber: return number != 0
        default: return true
        }
    }

    /// A stream URL from the manifest, accepted only as http(s): a manifest
    /// must never point the downloader at a local file.
    static func streamURL(_ text: String) throws(TIDALManifestError) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else {
            throw .invalidStreamURL
        }
        return url
    }
}

/// `dump` and reflecting loggers read a value's mirror rather than its
/// description, so the location's mirror hides the signed links as well
/// (G5-16). A manifest's own default mirror then holds nothing secret.
extension TIDALManifest.Location: CustomStringConvertible, CustomReflectable {
    /// The shape only (`direct` or `12 segments`), never a URL.
    public var description: String {
        switch self {
        case .direct: "direct"
        case .segments(_, let media): "\(media.count) segments"
        }
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["shape": description], displayStyle: .enum)
    }
}

/// Why a manifest couldn't be used. The messages are written for the person
/// and never contain a URL or TIDAL's raw reply (G5-16).
public enum TIDALManifestError: Error, Sendable, Hashable, LocalizedError {
    /// The playback reply had no manifest.
    case missingManifest
    /// The manifest wasn't valid base64.
    case unreadableEncoding
    /// A manifest type the app doesn't know (nil when TIDAL named none).
    case unsupportedType(String?)
    /// The track is encrypted: a BTS `encryptionType` other than `NONE`, or a
    /// DASH `ContentProtection` element (which Electron never checked).
    case copyProtected(String)
    /// The BTS manifest had no `urls`.
    case noStreamURL
    /// A URL in the manifest isn't a usable web link.
    case invalidStreamURL
    /// The JSON or XML inside couldn't be read.
    case unreadableManifest
    /// A DASH manifest with neither a `SegmentTemplate` (with `initialization`
    /// and `media`) nor a lone `BaseURL`.
    case missingSegmentTemplate
    /// A DASH segment template whose timeline lists no segments.
    case noSegments
    /// A timeline entry with a negative repeat (`r="-1"`, "until the end"),
    /// which needs durations to expand. Electron counted it as one segment and
    /// saved a cut-short file; refusing is safer.
    case openEndedTimeline
    /// A template placeholder other than `$Number$` (for example `$Time$`),
    /// which would otherwise be sent to TIDAL literally.
    case unsupportedTemplate(String)
    /// More segments than any real track has, a sign of a broken manifest.
    case tooManySegments

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            "TIDAL didn't send stream details for this track. Try again in a moment."
        case .unreadableEncoding, .unreadableManifest:
            "TIDAL sent stream details the app can't read. Try again later; if it keeps happening, the app may need an update."
        case .unsupportedType(let type):
            if let type, !type.isEmpty {
                "TIDAL sent this track in a stream format the app doesn't support (\(type)). The app may need an update."
            } else {
                "TIDAL didn't say which stream format this track uses. Try again later."
            }
        case .copyProtected:
            "TIDAL sent this track with copy protection, so it can't be saved."
        case .noStreamURL, .invalidStreamURL:
            "TIDAL's stream details had no usable link for this track. Try again in a moment."
        case .missingSegmentTemplate, .noSegments, .openEndedTimeline, .unsupportedTemplate, .tooManySegments:
            "TIDAL split this track's stream in a way the app can't follow. The app may need an update."
        }
    }
}
