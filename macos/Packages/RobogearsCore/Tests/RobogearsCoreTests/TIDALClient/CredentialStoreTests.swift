import Foundation
import Security
import Testing
@testable import RobogearsCore

@Suite("Credential stores")
struct CredentialStoreTests {
    // MARK: The credential format

    @Test func credentialSurvivesARoundTripThroughItsStoredForm() throws {
        let credential = TIDALClientFixtures.credential(refused: true)
        let decoded = try TIDALCredential.decoded(from: try credential.encoded())
        #expect(decoded == credential)
    }

    @Test func storedFormHoldsNoClientSecretAndUsesMilliseconds() throws {
        let credential = TIDALClientFixtures.credential(expiresAt: Date(timeIntervalSince1970: 1_800_003_000))
        let json = try #require(try JSONSerialization.jsonObject(with: try credential.encoded()) as? [String: Any])
        #expect(Set(json.keys) == ["version", "access_token", "refresh_token", "user_id", "country_code", "expires_at_ms", "client_pair", "refused"])
        #expect(json["expires_at_ms"] as? Double == 1_800_003_000_000)
        #expect(json["client_pair"] as? String == "test-renewal")
    }

    @Test func formatWithoutRefusedFlagReadsAsNotRefused() throws {
        let text = """
        {"access_token":"a","refresh_token":"r","expires_at_ms":1800000000000,"client_pair":"test-renewal"}
        """
        let credential = try TIDALCredential.decoded(from: Data(text.utf8))
        #expect(!credential.isRefused)
        #expect(credential.userID == nil)
    }

    @Test func printingACredentialNeverShowsItsTokens() {
        let credential = TIDALClientFixtures.credential(access: "secret-access", refresh: "secret-refresh")
        var dumped = ""
        dump(credential, to: &dumped)
        let texts = [String(describing: credential), String(reflecting: credential), dumped]
        let leaks = texts.contains { $0.contains("secret-access") || $0.contains("secret-refresh") }
        #expect(!leaks)
    }

    // MARK: File store

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("robogears-tidal-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func fileStoreRoundTripsTheSignIn() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileCredentialStore(fileURL: folder.appendingPathComponent("tidal-sign-in.json"))
        let credential = TIDALClientFixtures.credential()
        try store.write(credential)
        #expect(try store.read() == credential)
    }

    @Test func fileIsPrivateToTheUserAndItsFolderToo() throws {
        let folder = temporaryFolder().appendingPathComponent("robogears Downloader", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = folder.appendingPathComponent("tidal-sign-in.json")
        try FileCredentialStore(fileURL: file).write(TIDALClientFixtures.credential())
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
    }

    @Test func rewriteReplacesTheFileAtomicallyAndLeavesNoTemporaryFile() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tidal-sign-in.json")
        let store = FileCredentialStore(fileURL: file)
        try store.write(TIDALClientFixtures.credential(access: "first"))
        // A file left world-readable by something else is replaced, not reused.
        chmod(file.path, 0o644)
        try store.write(TIDALClientFixtures.credential(access: "second"))
        #expect(try store.read()?.accessToken == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["tidal-sign-in.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func missingFileMeansSignedOut() throws {
        let store = FileCredentialStore(fileURL: temporaryFolder().appendingPathComponent("tidal-sign-in.json"))
        #expect(try store.read() == nil)
    }

    @Test func damagedFileIsReportedNotTreatedAsSignedOut() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("tidal-sign-in.json")
        try Data("{\"access_tok".utf8).write(to: file)
        #expect(throws: CredentialStoreError.undecodable) { try FileCredentialStore(fileURL: file).read() }
    }

    @Test func unreadableFileIsItsOwnErrorNotSignedOut() throws {
        let folder = temporaryFolder()
        defer {
            chmod(folder.appendingPathComponent("tidal-sign-in.json").path, 0o600)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("tidal-sign-in.json")
        let store = FileCredentialStore(fileURL: file)
        try store.write(TIDALClientFixtures.credential())
        chmod(file.path, 0o000)
        #expect(throws: CredentialStoreError.unreadable(detail: "Permission denied")) { try store.read() }
    }

    @Test func deletingRemovesTheFileAndToleratesItBeingGone() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileCredentialStore(fileURL: folder.appendingPathComponent("tidal-sign-in.json"))
        try store.write(TIDALClientFixtures.credential())
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()
    }

    @Test func defaultFileIsNotTheElectronTokenFile() {
        let url = FileCredentialStore.defaultFileURL()
        #expect(url.lastPathComponent == "tidal-sign-in.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "robogears Downloader")
        #expect(url.path.contains("Application Support"))
    }

    // MARK: Keychain store (fake Security framework)

    private func string(_ value: Any?) -> String? { value as? String }

    @Test func keychainItemIsAGenericPasswordInTheLoginKeychain() throws {
        let keychain = TIDALFakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        try store.write(TIDALClientFixtures.credential())
        let add = try #require(keychain.calls.first { $0.kind == "add" })
        #expect(string(add.query[kSecClass as String]) == kSecClassGenericPassword as String)
        #expect(string(add.query[kSecAttrService as String]) == "com.robogears.downloader")
        #expect(string(add.query[kSecAttrAccount as String]) == "tidal-sign-in")
        #expect(add.query[kSecValueData as String] as? Data != nil)
        // Leaving this key out selects the legacy login keychain (G1-6).
        #expect(add.query[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test func keychainWriteUpdatesTheExistingItemInsteadOfAddingAnother() throws {
        let keychain = TIDALFakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        try store.write(TIDALClientFixtures.credential(access: "first"))
        try store.write(TIDALClientFixtures.credential(access: "second"))
        #expect(keychain.calls.map(\.kind) == ["update", "add", "update"])
        #expect(try store.read()?.accessToken == "second")
    }

    @Test func noKeychainItemMeansSignedOut() throws {
        #expect(try KeychainCredentialStore(keychain: TIDALFakeKeychain()).read() == nil)
    }

    @Test func lockedOrDeniedKeychainIsReportedNotTreatedAsSignedOut() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            let keychain = TIDALFakeKeychain(item: try TIDALClientFixtures.credential().encoded())
            keychain.copyStatusOverride = status
            let store = KeychainCredentialStore(keychain: keychain)
            var reportedUnreadable = false
            do { _ = try store.read() } catch { if case .unreadable = error { reportedUnreadable = true } }
            #expect(reportedUnreadable, "status \(status)")
        }
    }

    @Test func damagedKeychainItemIsReportedAsDamaged() throws {
        let store = KeychainCredentialStore(keychain: TIDALFakeKeychain(item: Data("not json".utf8)))
        #expect(throws: CredentialStoreError.undecodable) { try store.read() }
    }

    @Test func refusedKeychainWriteIsReported() throws {
        let keychain = TIDALFakeKeychain()
        keychain.addStatusOverride = errSecAuthFailed
        var reportedUnwritable = false
        do { try KeychainCredentialStore(keychain: keychain).write(TIDALClientFixtures.credential()) } catch {
            if case .unwritable = error { reportedUnwritable = true }
        }
        #expect(reportedUnwritable)
    }

    @Test func keychainDeleteToleratesAMissingItemButReportsOtherFailures() throws {
        let keychain = TIDALFakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        try store.delete()
        keychain.deleteStatusOverride = errSecInteractionNotAllowed
        var reported = false
        do { try store.delete() } catch { reported = true }
        #expect(reported)
    }

    /// Touches the real login keychain, so it runs only when asked:
    /// `ROBOGEARS_LIVE_KEYCHAIN_TEST=1 swift test --filter realLoginKeychain`.
    /// It uses a throwaway service name and removes the item afterwards.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROBOGEARS_LIVE_KEYCHAIN_TEST"] == "1"))
    func realLoginKeychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "com.robogears.downloader.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        let credential = TIDALClientFixtures.credential()
        try store.write(credential)
        #expect(try store.read() == credential)
        try store.delete()
        #expect(try store.read() == nil)
    }
}
