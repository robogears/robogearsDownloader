import Foundation
import RobogearsCore

/// Where the app keeps what it saves: settings, the queue, the update cache,
/// a few small values (the Move to Applications offer, a skipped update, the
/// activity panel's height), and where it looks for the previous version's
/// files.
///
/// The running app uses the person's real folders. The debug instruments
/// (`--run-checks`, `--render-snapshots`) call `isolateForInstrument()` before
/// anything else, which points every location at a fresh temporary folder and
/// keeps the small values in memory, so an instrument run can never read or
/// write the person's Application Support folder or preferences. (26 Oct: a
/// test run left a real settings file with a download folder in it, so a
/// first launch looked as if a default folder existed; product rule 1 says
/// the download folder starts blank.)
@MainActor
enum StorageLocation {
    /// The instrument run's own folder; nil in the running app.
    private static var instrumentRoot: URL?

    /// UserDefaults in the running app; a dictionary in an instrument run.
    private(set) static var values: any SmallValueStore = UserDefaults.standard

    /// True once `isolateForInstrument()` has run.
    static var isIsolated: Bool { instrumentRoot != nil }

    /// Application Support/com.robogears.downloader, or the instrument run's
    /// stand-in for it inside its temporary folder.
    static var supportDirectory: URL {
        instrumentRoot.map { $0.appendingPathComponent("com.robogears.downloader", isDirectory: true) }
            ?? AppPaths.supportDirectory()
    }

    /// Application Support/robogears Downloader (the Electron app's files), or
    /// the instrument run's empty stand-in for it.
    static var legacyElectronDirectory: URL {
        instrumentRoot.map { $0.appendingPathComponent("robogears Downloader", isDirectory: true) }
            ?? AppPaths.legacyElectronDirectory()
    }

    /// Called first thing by the debug instruments. Idempotent.
    static func isolateForInstrument() {
        guard instrumentRoot == nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("robogears-instrument-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        instrumentRoot = root
        values = InMemoryValues()
    }

    /// Removes the instrument run's temporary folder (only the one it made).
    static func removeInstrumentFolder() {
        guard let root = instrumentRoot, root.lastPathComponent.hasPrefix("robogears-instrument-") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// The few small values kept outside the settings file.
protocol SmallValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func double(forKey key: String) -> Double
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SmallValueStore {}

/// Small values for an instrument run: nothing reaches the person's preferences.
final class InMemoryValues: SmallValueStore {
    private var storage: [String: Any] = [:]

    func string(forKey key: String) -> String? { storage[key] as? String }
    func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }
    func double(forKey key: String) -> Double { storage[key] as? Double ?? 0 }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    func removeObject(forKey key: String) { storage[key] = nil }
}
