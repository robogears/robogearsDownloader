import Foundation

/// The result of asking GitHub whether a newer release exists (§2, §6).
public enum UpdateCheckResult: Equatable, Sendable {
    case available(AvailableUpdate)
    case upToDate
    /// A 404: the repository has no published release yet. Not an error.
    case noReleases
    case rateLimited(retryAfterSeconds: Int?)
    /// Offline is normal on a laptop, so it is reported apart from errors.
    case offline
    case failed(String)
}

/// Where the updater talks to and how. Production uses the defaults; the
/// test harness may point `apiBase` at a local mock, but only when
/// `overridesAllowed` (a debug build, or UPDATER_ALLOW_INSECURE_OVERRIDE=1).
public struct UpdaterConfiguration: Sendable {
    public var owner = "robogears"
    public var repository = "robogearsDownloader"
    public var appName = "robogears Downloader"
    public var bundleIdentifier = "com.robogears.downloader"
    public var apiBase = "https://api.github.com"
    public var overridesAllowed = false
    /// update-check.json (the ETag cache) lives here.
    public var supportDirectory: URL

    public init(supportDirectory: URL) { self.supportDirectory = supportDirectory }

    /// The configuration for this process: overrides only in debug builds or
    /// with the explicit environment switch; never from UPDATER_API_BASE alone.
    public static func standard(isDebugBuild: Bool, environment: [String: String] = ProcessInfo.processInfo.environment,
                                supportDirectory: URL) -> UpdaterConfiguration {
        var c = UpdaterConfiguration(supportDirectory: supportDirectory)
        c.overridesAllowed = isDebugBuild || environment["UPDATER_ALLOW_INSECURE_OVERRIDE"] == "1"
        if c.overridesAllowed, let base = environment["UPDATER_API_BASE"], !base.isEmpty {
            c.apiBase = base
        }
        return c
    }
}

/// Fetches `releases/latest` with a persisted ETag: a 304 reply doesn't count
/// against GitHub's shared 60-requests-an-hour limit, so routine checks cost
/// nothing (§2).
public struct UpdateChecker: Sendable {
    struct CheckCache: Codable { var etag: String; var payload: Data }

    public let configuration: UpdaterConfiguration
    let session: URLSession

    public init(configuration: UpdaterConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    var cacheFile: URL { configuration.supportDirectory.appendingPathComponent("update-check.json") }

    public func check(currentVersion: String) async -> UpdateCheckResult {
        do {
            guard let release = try await fetchLatest() else { return .noReleases }
            if let update = UpdateAssets.evaluate(release, currentVersion: currentVersion) {
                return .available(update)
            }
            return .upToDate
        } catch let error as CheckError {
            switch error {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .http(let code): return .failed("GitHub answered with an error (\(code)). Try again later.")
            case .malformed: return .failed("GitHub's answer couldn't be read. Try again later.")
            }
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            return .offline
        } catch {
            return .failed("Couldn't reach GitHub. Try again later.")
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost,
    ]

    enum CheckError: Error { case rateLimited(Int?), http(Int), malformed }

    func fetchLatest() async throws -> GitHubRelease? {
        guard let url = URL(string: "\(configuration.apiBase)/repos/\(configuration.owner)/\(configuration.repository)/releases/latest"),
              UpdateAssets.isAllowedDownloadURL(url, overridesAllowed: configuration.overridesAllowed) else {
            throw CheckError.malformed
        }
        var request = URLRequest(url: url)
        // The ETag is managed here, not by URLCache: URLSession would otherwise
        // revalidate transparently and the 304 branch would never run.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("robogears-downloader-updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let cache = loadCache()
        if let etag = cache?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.malformed }
        switch http.statusCode {
        case 304:
            guard let cache else { throw CheckError.malformed }
            return try decode(cache.payload)
        case 200:
            let release = try decode(data)
            if let etag = http.value(forHTTPHeaderField: "ETag") { saveCache(CheckCache(etag: etag, payload: data)) }
            return release
        case 404:
            return nil
        case 403, 429:
            throw CheckError.rateLimited(UpdateAssets.retryAfter(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                rateLimitReset: http.value(forHTTPHeaderField: "X-RateLimit-Reset")))
        default:
            throw CheckError.http(http.statusCode)
        }
    }

    private func decode(_ data: Data) throws -> GitHubRelease {
        do { return try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw CheckError.malformed }
    }

    private func loadCache() -> CheckCache? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONDecoder().decode(CheckCache.self, from: data)
    }

    private func saveCache(_ cache: CheckCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: configuration.supportDirectory, withIntermediateDirectories: true)
        // Atomic: a crash mid-write leaves the previous cache, never half a file.
        try? data.write(to: cacheFile, options: .atomic)
    }
}
