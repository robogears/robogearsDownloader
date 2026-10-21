import Foundation

/// Everything the person sets in Settings. Starts blank: no download folder
/// until one is chosen (product rule 1, GUI half).
public struct AppSettings: Codable, Equatable, Sendable {
    public var downloadFolder: FolderReference?
    /// Read-only. Empty means the duplicate check is off.
    public var libraryFolder: FolderReference?
    /// The slider position 0…1. Audio plays at position² so the low end
    /// gets quiet faster (the Electron app restored this wrongly as the
    /// squared value; decision 4, item 5.3).
    public var previewVolume: Double
    public var playSoundEffects: Bool
    public var notifyWhenDownloadsFinish: Bool
    public var checkForUpdatesAutomatically: Bool

    public init() {
        previewVolume = 0.5
        playSoundEffects = true
        notifyWhenDownloadsFinish = false
        checkForUpdatesAutomatically = true
    }

    /// The gain to apply to preview playback.
    public var previewGain: Float { Float(min(1, max(0, previewVolume)) * min(1, max(0, previewVolume))) }

    /// "Reset Folders…": forgets both folders and nothing else — not the
    /// TIDAL sign-in, not the volume (the Electron reset also wiped the volume).
    public mutating func resetFolders() {
        downloadFolder = nil
        libraryFolder = nil
    }

    // Decoding tolerates missing keys so older or newer settings files load.
    enum CodingKeys: String, CodingKey {
        case downloadFolder, libraryFolder, previewVolume, playSoundEffects, notifyWhenDownloadsFinish, checkForUpdatesAutomatically
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        downloadFolder = try c.decodeIfPresent(FolderReference.self, forKey: .downloadFolder)
        libraryFolder = try c.decodeIfPresent(FolderReference.self, forKey: .libraryFolder)
        previewVolume = try c.decodeIfPresent(Double.self, forKey: .previewVolume) ?? defaults.previewVolume
        playSoundEffects = try c.decodeIfPresent(Bool.self, forKey: .playSoundEffects) ?? defaults.playSoundEffects
        notifyWhenDownloadsFinish = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenDownloadsFinish) ?? defaults.notifyWhenDownloadsFinish
        checkForUpdatesAutomatically = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically) ?? defaults.checkForUpdatesAutomatically
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/robogears Downloader — the same folder
    /// the Electron app used. The Swift app's files have their own names
    /// (settings-v2.json, queue-v2.json) and never read the old ones
    /// (decision D3: start from scratch).
    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("robogears Downloader", isDirectory: true)
    }

    public static func settingsFile(in dir: URL = supportDirectory()) -> URL { dir.appendingPathComponent("settings-v2.json") }
    public static func queueFile(in dir: URL = supportDirectory()) -> URL { dir.appendingPathComponent("queue-v2.json") }
}
