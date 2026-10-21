import Foundation
import Security

// MARK: - The credential

/// The one stored TIDAL sign-in.
///
/// It mirrors one Electron `token.json` entry, with two changes from the
/// cards: the client secret is never stored (only the renewal pair's label,
/// G1-7), and a refused renewal is remembered (`isRefused`), so Settings can
/// say "sign in again" after a relaunch without another network call (G1-8).
/// The access token and its expiry are stored too, so a relaunch doesn't
/// renew needlessly (G1-5 skeptic).
public struct TIDALCredential: Sendable, Equatable, Codable, CustomStringConvertible, CustomReflectable {
    public var accessToken: String
    public var refreshToken: String
    public var userID: Int?
    public var countryCode: String?
    /// When to renew. Already 60 s before TIDAL's real expiry, as today.
    public var expiresAt: Date
    /// The built-in client pair this sign-in renews with (`ClientPair.label`).
    public var clientPairLabel: String
    /// TIDAL refused to renew this sign-in; only signing in again helps.
    public var isRefused: Bool

    public init(
        accessToken: String,
        refreshToken: String,
        userID: Int?,
        countryCode: String?,
        expiresAt: Date,
        clientPairLabel: String,
        isRefused: Bool = false
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.countryCode = countryCode
        self.expiresAt = expiresAt
        self.clientPairLabel = clientPairLabel
        self.isRefused = isRefused
    }

    /// The format written to disk or the Keychain. `version` lets a later
    /// app tell its own format from this one.
    private enum CodingKeys: String, CodingKey {
        case version
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case userID = "user_id"
        case countryCode = "country_code"
        case expiresAt = "expires_at_ms"
        case clientPairLabel = "client_pair"
        case isRefused = "refused"
    }

    static let formatVersion = 1

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        userID = try container.decodeIfPresent(Int.self, forKey: .userID)
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        let milliseconds = try container.decode(Double.self, forKey: .expiresAt)
        expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        clientPairLabel = try container.decode(String.self, forKey: .clientPairLabel)
        isRefused = try container.decodeIfPresent(Bool.self, forKey: .isRefused) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(userID, forKey: .userID)
        try container.encodeIfPresent(countryCode, forKey: .countryCode)
        try container.encode((expiresAt.timeIntervalSince1970 * 1000).rounded(), forKey: .expiresAt)
        try container.encode(clientPairLabel, forKey: .clientPairLabel)
        try container.encode(isRefused, forKey: .isRefused)
    }

    /// Tokens are never shown, in logs, errors or `dump`.
    public var description: String {
        "TIDALCredential(user \(userID.map(String.init) ?? "unknown"), country \(countryCode ?? "unknown"), "
            + "pair \(clientPairLabel)\(isRefused ? ", refused" : ""))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "userID": userID as Any,
            "countryCode": countryCode as Any,
            "clientPairLabel": clientPairLabel,
            "isRefused": isRefused,
        ])
    }

    func encoded() throws(CredentialStoreError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do { return try encoder.encode(self) } catch {
            throw .unwritable(detail: "the sign-in couldn't be encoded")
        }
    }

    static func decoded(from data: Data) throws(CredentialStoreError) -> TIDALCredential {
        do { return try JSONDecoder().decode(TIDALCredential.self, from: data) } catch {
            throw .undecodable
        }
    }
}

// MARK: - Store protocol

/// Why the stored sign-in couldn't be read or written.
///
/// A read failure is never "signed out" (G1-6 skeptic note 2): if a locked
/// keychain or a Deny click looked like "no sign-in", the person would sign
/// in, the save would fail too, and the loop would repeat.
public enum CredentialStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The store exists but couldn't be read (permissions, keychain locked,
    /// access denied).
    case unreadable(detail: String)
    /// Something is stored but it isn't a sign-in this app can read. Signing
    /// in again replaces it.
    case undecodable
    case unwritable(detail: String)

    public var description: String {
        switch self {
        case let .unreadable(detail): return "Can't read your TIDAL sign-in: \(detail)"
        case .undecodable: return "Your saved TIDAL sign-in is damaged. Sign in again to replace it."
        case let .unwritable(detail): return "Can't save your TIDAL sign-in: \(detail)"
        }
    }
}

/// Where the one sign-in lives. Two implementations: a private file and the
/// Keychain (G1-6; which one the app uses is the owner's call there).
///
/// Synchronous on purpose: the token keeper calls it from inside its actor,
/// so a save can never interleave with a later change and write a stale
/// sign-in last. The keeper never runs on the main actor, so a Keychain
/// prompt that waits for the person blocks no window.
public protocol CredentialStore: Sendable {
    /// Nil only when nothing is stored. Any other problem throws.
    func read() throws(CredentialStoreError) -> TIDALCredential?
    func write(_ credential: TIDALCredential) throws(CredentialStoreError)
    /// Removing a sign-in that isn't there is not an error.
    func delete() throws(CredentialStoreError)
}

// MARK: - File store

/// The sign-in as one private file (G1-6 option 2): mode 0600, written
/// atomically so a crash mid-write never leaves a broken file (the Electron
/// app overwrote `token.json` in place: reference M10).
///
/// `Data.write(options: .atomic)` alone would create the temporary file with
/// default permissions (G1-6 skeptic note 4), so the temporary file is
/// created 0600 by hand, filled, flushed, and renamed over the old one.
public struct FileCredentialStore: CredentialStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The Swift app's own file. Deliberately not `token.json`: the
    /// Electron app's file may sit in the same folder, and the owner decided
    /// the Swift app starts fresh and never reads it (D3).
    public static func defaultFileURL(appFolderName: String = "robogears Downloader") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("tidal-sign-in.json", isDirectory: false)
    }

    public func read() throws(CredentialStoreError) -> TIDALCredential? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        } catch {
            throw .unreadable(detail: Self.plainReason(error))
        }
        return try TIDALCredential.decoded(from: data)
    }

    public func write(_ credential: TIDALCredential) throws(CredentialStoreError) {
        let data = try credential.encoded()
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .unwritable(detail: Self.plainReason(error))
        }

        let temporaryPath = directory
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            .path
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw .unwritable(detail: String(cString: strerror(errno)))
        }
        var succeeded = false
        defer {
            if !succeeded { unlink(temporaryPath) }
        }
        // The umask can only remove bits, but set 0600 explicitly anyway.
        fchmod(descriptor, 0o600)
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += result
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        guard failure == 0 else {
            throw .unwritable(detail: String(cString: strerror(failure)))
        }
        guard rename(temporaryPath, fileURL.path) == 0 else {
            throw .unwritable(detail: String(cString: strerror(errno)))
        }
        succeeded = true
    }

    public func delete() throws(CredentialStoreError) {
        if unlink(fileURL.path) != 0 && errno != ENOENT {
            throw .unwritable(detail: String(cString: strerror(errno)))
        }
    }

    /// The system's reason without the file path (paths can name folders the
    /// person considers private; manual 6.3).
    private static func plainReason(_ error: any Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(nsError.code)))
        }
        return "error \(nsError.code)"
    }
}

// MARK: - Keychain store

/// The four Keychain calls the store makes, behind a seam so tests check the
/// exact queries and every status path without touching the person's real
/// login keychain (which could show a prompt nobody is there to answer).
public protocol KeychainAPI: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The real Security framework.
public struct SystemKeychain: KeychainAPI {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// The sign-in as one generic-password item in the login keychain (G1-6
/// option 1).
///
/// It uses the legacy (file-based) login keychain on purpose: the modern
/// data-protection keychain needs a keychain-access-groups entitlement,
/// which needs an Apple team ID this project doesn't have (G1-6 skeptic
/// note 1). The legacy keychain ties access to the code signature, which is
/// why the card pairs it with one long-lived self-signed certificate.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "com.robogears.downloader"
    public static let defaultAccount = "tidal-sign-in"

    public let service: String
    public let account: String
    private let keychain: any KeychainAPI

    public init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = KeychainCredentialStore.defaultAccount,
        keychain: any KeychainAPI = SystemKeychain()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    /// Identifies the one item. `kSecUseDataProtectionKeychain` is left out
    /// (it defaults to false on macOS), which selects the login keychain.
    var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws(CredentialStoreError) -> TIDALCredential? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data else { throw .undecodable }
            return try TIDALCredential.decoded(from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw .unreadable(detail: Self.describe(status))
        }
    }

    public func write(_ credential: TIDALCredential) throws(CredentialStoreError) {
        let data = try credential.encoded()
        let updateStatus = keychain.update(itemQuery, [kSecValueData as String: data])
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = itemQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "robogears Downloader TIDAL sign-in"
            let addStatus = keychain.add(attributes)
            guard addStatus == errSecSuccess else {
                throw .unwritable(detail: Self.describe(addStatus))
            }
        default:
            throw .unwritable(detail: Self.describe(updateStatus))
        }
    }

    public func delete() throws(CredentialStoreError) {
        let status = keychain.delete(itemQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .unwritable(detail: Self.describe(status))
        }
    }

    /// The system's own words for a Keychain status, plus the number.
    static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
        return "\(message) (\(status))"
    }
}
