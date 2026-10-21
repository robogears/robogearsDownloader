import Foundation
import Testing
@testable import RobogearsCore

// MARK: - Version rules

@Test func versionCompareIsNumericNotAlphabetic() {
    #expect(UpdateVersion.isNewer("0.1.10", than: "0.1.9"))
    #expect(!UpdateVersion.isNewer("0.1.9", than: "0.1.10"))
}

@Test func versionCompareIgnoresALeadingVInEitherCase() {
    #expect(UpdateVersion.isNewer("v0.1.31", than: "0.1.30"))
    #expect(UpdateVersion.isNewer("V0.1.31", than: "v0.1.30"))
    #expect(!UpdateVersion.isNewer("v0.1.30", than: "0.1.30"))
}

@Test func missingVersionSegmentsCountAsZero() {
    #expect(!UpdateVersion.isNewer("1.0", than: "1.0.0"))
    #expect(UpdateVersion.isNewer("1.0.1", than: "1.0"))
}

@Test func aPrereleaseNeverOutranksItsOwnRelease() {
    #expect(UpdateVersion.isNewer("0.2.1", than: "0.2.1-rc.1"))
    #expect(!UpdateVersion.isNewer("0.2.1-rc.1", than: "0.2.1"))
    #expect(UpdateVersion.isNewer("0.2.1-rc.1", than: "0.1.31"))
}

@Test func tagsThatAreNotVersionsAreIgnored() {
    #expect(UpdateVersion.isVersionTag("v0.1.31"))
    #expect(UpdateVersion.isVersionTag("0.2.1-rc.1"))
    #expect(!UpdateVersion.isVersionTag("latest"))
    #expect(!UpdateVersion.isVersionTag("v1..2"))
    #expect(!UpdateVersion.isVersionTag(""))
}

@Test func theFirstSwiftReleaseIsOfferedToElectronUsers() {
    // The v0.1.30 Electron updater must see the Swift app as newer.
    #expect(UpdateVersion.isNewer(RobogearsCore.version, than: "0.1.30"))
}

// MARK: - Assets and integrity

private func release(_ tag: String, assets: [String]) -> GitHubRelease {
    GitHubRelease(tag_name: tag, html_url: "https://github.com/robogears/robogearsDownloader/releases/tag/\(tag)",
                  body: "Notes for \(tag)",
                  assets: assets.map { .init(name: $0, browser_download_url: "https://github.com/robogears/robogearsDownloader/releases/download/\(tag)/\($0)", size: 90_000_000) })
}

@Test func theArm64ZipAndItsSidecarAreChosen() {
    let r = release("v0.1.32", assets: ["robogears-downloader-mac-arm64.dmg", "robogears-downloader-mac-arm64.zip",
                                        "robogears-downloader-mac-arm64.zip.sha256"])
    let (asset, sha) = UpdateAssets.matchAsset(in: r, arch: "arm64")
    #expect(asset?.name == "robogears-downloader-mac-arm64.zip")
    #expect(sha?.name == "robogears-downloader-mac-arm64.zip.sha256")
}

@Test func aUniversalZipIsTheOnlyFallback() {
    let r = release("v0.1.32", assets: ["robogears-downloader-mac-universal.zip"])
    #expect(UpdateAssets.matchAsset(in: r, arch: "arm64").asset?.name == "robogears-downloader-mac-universal.zip")
}

@Test func aWrongArchitectureZipIsNeverOffered() {
    let r = release("v0.1.32", assets: ["robogears-downloader-mac-x86_64.zip", "robogears-downloader-mac-arm64.dmg"])
    #expect(UpdateAssets.matchAsset(in: r, arch: "arm64").asset == nil)
    // The update is still announced, but with no download: the UI opens the release page.
    let update = UpdateAssets.evaluate(r, currentVersion: "0.1.31", arch: "arm64")
    #expect(update?.version == "0.1.32")
    #expect(update?.assetURL == nil)
    #expect(update?.releaseURL != nil)
}

@Test func anOlderOrEqualReleaseIsNotAnUpdate() {
    #expect(UpdateAssets.evaluate(release("v0.1.31", assets: []), currentVersion: "0.1.31") == nil)
    #expect(UpdateAssets.evaluate(release("v0.1.30", assets: []), currentVersion: "0.1.31") == nil)
    #expect(UpdateAssets.evaluate(release("nightly", assets: []), currentVersion: "0.1.31") == nil)
}

@Test func sidecarsMustHoldA64CharacterDigest() {
    let digest = String(repeating: "ab", count: 32)
    #expect(UpdateAssets.parseSidecar("\(digest)  robogears-downloader-mac-arm64.zip\n") == digest)
    #expect(UpdateAssets.parseSidecar(digest.uppercased()) == digest)
    #expect(UpdateAssets.parseSidecar("not a digest") == nil)
    #expect(UpdateAssets.parseSidecar("") == nil)
}

@Test func sha256StreamsAFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("updater-sha-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try UpdateAssets.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func aChecksumMismatchDeletesTheDownloadAndStops() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("updater-bad-\(UUID().uuidString)")
    try Data("corrupt".utf8).write(to: file)
    #expect(throws: UpdateInstallError.checksumMismatch) {
        try UpdateInstaller.verify(file: file, expectedSHA256: String(repeating: "0", count: 64))
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func onlyGitHubHostsOverHTTPSAreAllowed() {
    func allowed(_ s: String, overrides: Bool = false) -> Bool {
        UpdateAssets.isAllowedDownloadURL(URL(string: s)!, overridesAllowed: overrides)
    }
    #expect(allowed("https://github.com/robogears/robogearsDownloader/releases/download/v1/a.zip"))
    #expect(allowed("https://objects.githubusercontent.com/github-production-release-asset/x"))
    #expect(allowed("https://api.github.com/repos/robogears/robogearsDownloader/releases/latest"))
    #expect(!allowed("http://github.com/a.zip"))
    #expect(!allowed("https://github.com.evil.example/a.zip"))
    #expect(!allowed("https://example.com/a.zip"))
    // The test harness's local mock works only when overrides are allowed.
    #expect(!allowed("http://127.0.0.1:8787/a.zip"))
    #expect(allowed("http://127.0.0.1:8787/a.zip", overrides: true))
}

@Test func retryAfterReadsEitherHeader() {
    #expect(UpdateAssets.retryAfter(retryAfterHeader: "30", rateLimitReset: nil) == 30)
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(UpdateAssets.retryAfter(retryAfterHeader: nil, rateLimitReset: "1090", now: now) == 90)
    #expect(UpdateAssets.retryAfter(retryAfterHeader: nil, rateLimitReset: nil) == nil)
}

@Test func overridesNeedADebugBuildOrTheExplicitSwitch() {
    let dir = FileManager.default.temporaryDirectory
    let env = ["UPDATER_API_BASE": "http://127.0.0.1:8787"]
    #expect(UpdaterConfiguration.standard(isDebugBuild: false, environment: env, supportDirectory: dir).apiBase == "https://api.github.com")
    #expect(UpdaterConfiguration.standard(isDebugBuild: true, environment: env, supportDirectory: dir).apiBase == "http://127.0.0.1:8787")
    var switched = env
    switched["UPDATER_ALLOW_INSECURE_OVERRIDE"] = "1"
    #expect(UpdaterConfiguration.standard(isDebugBuild: false, environment: switched, supportDirectory: dir).apiBase == "http://127.0.0.1:8787")
}

// MARK: - Where the update installs

@Test func aNormalInstallUpdatesInPlace() {
    let running = URL(fileURLWithPath: "/Applications/robogears Downloader.app")
    let dest = UpdateInstaller.installDestination(runningBundle: running, appName: "robogears Downloader", isWritable: { _ in true })
    #expect(dest == running)
}

@Test func aTranslocatedCopyInstallsToApplications() {
    let running = URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/robogears Downloader.app")
    let dest = UpdateInstaller.installDestination(runningBundle: running, appName: "robogears Downloader", isWritable: { _ in true })
    #expect(dest.path == "/Applications/robogears Downloader.app")
}

@Test func withoutAdminRightsItFallsBackToTheHomeApplicationsFolder() {
    let running = URL(fileURLWithPath: "/Applications/robogears Downloader.app")
    let home = URL(fileURLWithPath: "/Users/someone")
    let dest = UpdateInstaller.installDestination(runningBundle: running, appName: "robogears Downloader",
                                                  isWritable: { _ in false }, home: home)
    #expect(dest.path == "/Users/someone/Applications/robogears Downloader.app")
}

@Test func debugBuildsNeverSelfInstall() {
    let dest = URL(fileURLWithPath: "/Applications/robogears Downloader.app")
    #expect(!UpdateInstaller.canSelfInstall(isDebugBuild: true, destination: dest, isWritable: { _ in true }))
    #expect(UpdateInstaller.canSelfInstall(isDebugBuild: false, destination: dest, isWritable: { _ in true }))
    #expect(!UpdateInstaller.canSelfInstall(isDebugBuild: false, destination: dest, isWritable: { _ in false }))
}

// MARK: - The relauncher

@Test func relauncherKeepsEverySafetyStep() throws {
    let script = UpdateInstaller.relauncherScript(appName: "robogears Downloader")
    // Survives the app quitting.
    #expect(script.contains(#"nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 &"#))
    #expect(script.contains(#"trap "" HUP TERM"#))
    // Never swaps under a live process.
    #expect(script.contains(#"echo "ERROR: old app never exited; aborting""#))
    // A failed backup reopens the intact old app.
    #expect(script.contains(#"echo "ERROR: backup failed; aborting"; open "$TARGET"; rm -f "$0"; exit 1"#))
    // Only a re-signed AND verified bundle earns deleting the backup.
    #expect(script.contains(#"if codesign --force --deep --sign - "$TARGET" && codesign --verify --deep --strict "$TARGET"; then"#))
    // Logs where the person can find them after the app has gone.
    #expect(script.contains(#"LOGDIR="$HOME/Library/Logs/robogears Downloader""#))
    // Paths arrive as arguments, never pasted into the script.
    #expect(!script.contains("/Applications/"))
}

@Test func relauncherIsValidBash() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("relauncher-\(UUID().uuidString).sh")
    try UpdateInstaller.relauncherScript(appName: "robogears Downloader").write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    try UpdateInstaller.runTool("/bin/bash", ["-n", file.path])
}

// MARK: - Unpacking and identity

private func makeSignedZip(bundleID: String, version: String, appName: String = "robogears Downloader") throws -> URL {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("updater-pkg-\(UUID().uuidString)")
    let app = work.appendingPathComponent("\(appName).app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
        "CFBundleExecutable": "app", "CFBundlePackageType": "APPL", "CFBundleName": appName,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let exe = app.appendingPathComponent("Contents/MacOS/app")
    try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    try UpdateInstaller.runTool("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
    let zip = work.appendingPathComponent("update.zip")
    try UpdateInstaller.runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path])
    return zip
}

@Test func aSignedBundleOfThisAppIsStaged() throws {
    let zip = try makeSignedZip(bundleID: "com.robogears.downloader", version: "0.1.32")
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("updater-stage-\(UUID().uuidString)")
    let app = try UpdateInstaller.unpackAndValidate(zip: zip, expectedVersion: "0.1.32", appName: "robogears Downloader",
                                                   bundleIdentifier: "com.robogears.downloader", stagingRoot: staging)
    #expect(app.lastPathComponent == "robogears Downloader.app")
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    try? FileManager.default.removeItem(at: staging)
}

@Test func aBundleOfAnotherAppIsRefused() throws {
    let zip = try makeSignedZip(bundleID: "com.example.other", version: "0.1.32")
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("updater-stage-\(UUID().uuidString)")
    #expect(throws: UpdateInstallError.badPackage("it is a different app.")) {
        try UpdateInstaller.unpackAndValidate(zip: zip, expectedVersion: "0.1.32", appName: "robogears Downloader",
                                              bundleIdentifier: "com.robogears.downloader", stagingRoot: staging)
    }
}

@Test func aBundleOlderThanTheReleaseIsRefused() throws {
    let zip = try makeSignedZip(bundleID: "com.robogears.downloader", version: "0.1.30")
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("updater-stage-\(UUID().uuidString)")
    #expect(throws: UpdateInstallError.badPackage("it is older than the release it came from.")) {
        try UpdateInstaller.unpackAndValidate(zip: zip, expectedVersion: "0.1.32", appName: "robogears Downloader",
                                              bundleIdentifier: "com.robogears.downloader", stagingRoot: staging)
    }
}

@Test func staleStagingIsSweptButFreshStagingStays() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("updater-sweep-\(UUID().uuidString)")
    let old = dir.appendingPathComponent("robogears Downloader-update-old")
    let fresh = dir.appendingPathComponent("robogears Downloader-update-fresh")
    let other = dir.appendingPathComponent("unrelated-update-old")
    for d in [old, fresh, other] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
    try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: old.path)
    try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: other.path)
    UpdateInstaller.sweepStaleStaging(in: dir, appName: "robogears Downloader")
    #expect(!fm.fileExists(atPath: old.path))
    #expect(fm.fileExists(atPath: fresh.path))
    #expect(fm.fileExists(atPath: other.path))
    try? fm.removeItem(at: dir)
}

// MARK: - Checking GitHub (stubbed network)

/// Answers requests from a per-test handler instead of the network.
private final class UpdaterStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct UpdateCheckerNetworkTests {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("updater-check-\(UUID().uuidString)")

    func checker() -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdaterStubProtocol.self]
        return UpdateChecker(configuration: UpdaterConfiguration(supportDirectory: support),
                             session: URLSession(configuration: config))
    }

    func respond(_ status: Int, _ body: String = "", headers: [String: String] = [:],
                 inspect: (@Sendable (URLRequest) -> Void)? = nil) {
        UpdaterStubProtocol.handler = { request in
            inspect?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (response, Data(body.utf8))
        }
    }

    let newerRelease = #"{"tag_name":"v0.1.32","html_url":"https://github.com/robogears/robogearsDownloader/releases/tag/v0.1.32","body":"What's new","assets":[{"name":"robogears-downloader-mac-arm64.zip","browser_download_url":"https://github.com/robogears/robogearsDownloader/releases/download/v0.1.32/robogears-downloader-mac-arm64.zip","size":90000000}]}"#

    @Test func aNewerReleaseIsReportedWithItsNotes() async {
        respond(200, newerRelease, headers: ["ETag": "\"abc\""])
        let result = await checker().check(currentVersion: "0.1.31")
        guard case .available(let update) = result else { Issue.record("expected available, got \(result)"); return }
        #expect(update.version == "0.1.32")
        #expect(update.notes == "What's new")
        #expect(update.assetURL?.lastPathComponent == "robogears-downloader-mac-arm64.zip")
    }

    @Test func theETagIsSentAgainAndA304ReusesTheCachedRelease() async {
        respond(200, newerRelease, headers: ["ETag": "\"abc\""])
        _ = await checker().check(currentVersion: "0.1.31")
        let sentETag = UpdaterLockedBox<String?>(nil)
        respond(304, inspect: { sentETag.value = $0.value(forHTTPHeaderField: "If-None-Match") })
        let result = await checker().check(currentVersion: "0.1.31")
        #expect(sentETag.value == "\"abc\"")
        guard case .available(let update) = result else { Issue.record("expected available, got \(result)"); return }
        #expect(update.version == "0.1.32")
    }

    @Test func noPublishedReleaseIsNotAnError() async {
        respond(404, #"{"message":"Not Found"}"#)
        #expect(await checker().check(currentVersion: "0.1.31") == .noReleases)
    }

    @Test func rateLimitingSaysWhenToTryAgain() async {
        respond(403, #"{"message":"API rate limit exceeded"}"#, headers: ["Retry-After": "120"])
        #expect(await checker().check(currentVersion: "0.1.31") == .rateLimited(retryAfterSeconds: 120))
    }

    @Test func beingOfflineIsReportedApartFromErrors() async {
        UpdaterStubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await checker().check(currentVersion: "0.1.31") == .offline)
    }

    @Test func theSameVersionIsUpToDate() async {
        respond(200, newerRelease.replacingOccurrences(of: "v0.1.32", with: "v0.1.31"))
        #expect(await checker().check(currentVersion: "0.1.31") == .upToDate)
    }
}

/// A tiny thread-safe box for values captured by @Sendable test handlers.
private final class UpdaterLockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
