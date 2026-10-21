import Foundation

/// Saves the queue so it survives restarts (kept from v0.1.17), with the
/// Electron app's 400 ms debounce, an explicit flush for quitting, and
/// atomic writes.
public actor QueueStore {
    struct File: Codable, Sendable {
        var version = 1
        var items: [QueueItem]
    }

    private let store: JSONFileStore<File>
    private let debounce: Duration
    private var pending: [QueueItem]?
    private var saveTask: Task<Void, Never>?
    /// The last save error, for the UI to show once ("Your queue couldn't be saved…").
    public private(set) var lastError: String?

    public init(file: URL, debounce: Duration = .milliseconds(400)) {
        self.store = JSONFileStore(file: file)
        self.debounce = debounce
    }

    public enum LoadOutcome: Equatable, Sendable {
        case loaded([QueueItem])
        case empty
        /// The saved queue couldn't be read; it was kept aside at this path.
        case unreadable(keptAt: String?)
    }

    public func load() -> LoadOutcome {
        switch store.load() {
        case .loaded(let file): return .loaded(file.items.map(\.persisted))
        case .missing: return .empty
        case .unreadable(let kept): return .unreadable(keptAt: kept?.path)
        }
    }

    /// Schedules a save; several quick changes write once.
    public func save(_ items: [QueueItem]) {
        pending = items
        saveTask?.cancel()
        saveTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.writePending()
        }
    }

    /// Writes any pending change now (call on quit and after each finished track).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        writePending()
    }

    private func writePending() {
        guard let items = pending else { return }
        pending = nil
        do {
            try store.save(File(items: items.map(\.persisted)))
            lastError = nil
        } catch {
            lastError = "Your queue couldn't be saved (\(error.localizedDescription)). It's still here; check the startup disk has free space."
        }
    }
}

/// Loads and saves settings, with a damaged file kept aside.
public struct SettingsStore: Sendable {
    let store: JSONFileStore<AppSettings>

    public init(file: URL) { store = JSONFileStore(file: file) }

    public enum LoadOutcome: Sendable {
        case loaded(AppSettings)
        case fresh
        case unreadable(keptAt: String?)
    }

    public func load() -> (settings: AppSettings, outcome: LoadOutcome) {
        switch store.load() {
        case .loaded(let s): return (s, .loaded(s))
        case .missing: return (AppSettings(), .fresh)
        case .unreadable(let kept): return (AppSettings(), .unreadable(keptAt: kept?.path))
        }
    }

    public func save(_ settings: AppSettings) throws { try store.save(settings) }
}
