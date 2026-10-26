import CryptoKit
import Foundation

// Release discovery, asset matching and the integrity gate for the GitHub
// self-updater. Follows the owner's github-updater recipe for native Swift
// apps (core spec §2–§5); decision 4, item 5.6.

/// One GitHub release as `/releases/latest` returns it (only the fields used).
public struct GitHubRelease: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public let name: String
        public let browser_download_url: String
        public let size: Int64?
    }
    public let tag_name: String
    public let html_url: String?
    public let body: String?
    public let assets: [Asset]
}

/// What a check found, ready for the UI.
public struct AvailableUpdate: Equatable, Sendable {
    /// Tag without the leading v, e.g. "0.1.32".
    public let version: String
    /// Release notes, shown as "What's new" (no extra request).
    public let notes: String
    /// The release page: where the UI goes when it can't self-install.
    public let releaseURL: URL?
    /// nil when no asset matches this Mac (never a wrong-arch fallback).
    public let assetURL: URL?
    /// nil for a release without a sidecar: the download then rests on TLS alone.
    public let sha256URL: URL?
    public let assetSize: Int64
}

public enum UpdateAssets {
    /// The architecture this build runs as; asset names carry it (§4).
    public static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The updater's half of the asset-name contract. The release script names
    /// the zip `robogears-downloader-mac-<arch>.zip`; change both together.
    /// A universal zip is the only acceptable fallback: it contains both slices.
    public static func matchAsset(in release: GitHubRelease, arch: String = UpdateAssets.arch)
        -> (asset: GitHubRelease.Asset?, sha256: GitHubRelease.Asset?)
    {
        let exact = release.assets.first { $0.name.hasSuffix("-\(arch).zip") }
        let universal = release.assets.first { $0.name.hasSuffix("-universal.zip") }
        guard let asset = exact ?? universal else { return (nil, nil) }
        let sidecar = release.assets.first { $0.name == "\(asset.name).sha256" }
        return (asset, sidecar)
    }

    /// Turns a release into what the UI shows, or nil when it isn't newer.
    /// Tags that aren't version-shaped are ignored, never compared as zeros.
    public static func evaluate(_ release: GitHubRelease, currentVersion: String, arch: String = UpdateAssets.arch)
        -> AvailableUpdate?
    {
        guard UpdateVersion.isVersionTag(release.tag_name),
              UpdateVersion.isNewer(release.tag_name, than: currentVersion) else { return nil }
        let (asset, sidecar) = matchAsset(in: release, arch: arch)
        return AvailableUpdate(
            version: UpdateVersion.stripPrefix(release.tag_name),
            notes: release.body ?? "",
            releaseURL: release.html_url.flatMap(URL.init(string:)),
            assetURL: asset.flatMap { URL(string: $0.browser_download_url) },
            sha256URL: sidecar.flatMap { URL(string: $0.browser_download_url) },
            assetSize: asset?.size ?? 0
        )
    }

    /// Reads `shasum -a 256` output ("<64 hex>  <file name>"). Anything else
    /// counts as unreadable, which the updater treats like a missing sidecar.
    public static func parseSidecar(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first
        else { return nil }
        let hex = token.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    /// Streams the file through SHA-256; never loads a large download whole.
    public static func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Only GitHub's own hosts over HTTPS, checked again on every redirect
    /// hop. Overrides (the test harness) relax this only outside release builds.
    public static func isAllowedDownloadURL(_ url: URL, overridesAllowed: Bool) -> Bool {
        if overridesAllowed { return url.scheme == "https" || url.scheme == "http" }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "api.github.com"
            || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Seconds to wait from `Retry-After` (seconds) or `X-RateLimit-Reset`
    /// (epoch seconds), so the UI can say when to try again.
    public static func retryAfter(retryAfterHeader: String?, rateLimitReset: String?, now: Date = Date()) -> Int? {
        if let value = retryAfterHeader.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), value >= 0 {
            return value
        }
        if let reset = rateLimitReset.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }) {
            return max(0, Int((reset - now.timeIntervalSince1970).rounded(.up)))
        }
        return nil
    }
}

/// Version comparison for release tags (§3): leading v stripped in any case,
/// numeric segments compared left to right, missing segments are 0, and a
/// pre-release never outranks its own release. The comparing itself is
/// `VersionNumber`'s, so there is one rule in the app.
public enum UpdateVersion {
    public static func stripPrefix(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    /// True for "1.2.3", "v0.1.31", "0.2.1-rc.1"; false for "latest", "".
    public static func isVersionTag(_ s: String) -> Bool {
        let core = stripPrefix(s).split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return !core.isEmpty && core.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// One comparison serves the updater and everything else: the port of
    /// the Electron rule in VersionCompare.swift, after the case-insensitive
    /// prefix strip above. Pre-releases order by their identifiers, so
    /// "0.2.1-rc.2" is newer than "0.2.1-rc.1".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        VersionCompare.isNewer(stripPrefix(candidate), than: stripPrefix(current))
    }
}
