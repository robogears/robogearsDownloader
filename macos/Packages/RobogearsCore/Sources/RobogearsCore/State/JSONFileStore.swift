import Foundation

/// Reads and writes one Codable value as a JSON file, safely:
/// - writes are atomic (a temporary file renamed over the old one), so a
///   crash or full disk never leaves half a file;
/// - a file that exists but can't be read is moved aside, never overwritten,
///   and the caller is told so it can say what happened.
/// The Electron app wrote settings.json and queue.json in place and treated
/// an unreadable file as empty, silently (flow-failures-and-data-safety.md).
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public enum LoadResult: Sendable {
        case loaded(Value)
        /// No file yet (first launch).
        case missing
        /// The file couldn't be read; it was kept at `keptAt`.
        case unreadable(keptAt: URL?)
    }

    public let file: URL
    /// File permissions for the saved file (0600 for anything private).
    public let permissions: Int

    public init(file: URL, permissions: Int = 0o644) {
        self.file = file
        self.permissions = permissions
    }

    public func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return .missing }
        do {
            let data = try Data(contentsOf: file)
            return .loaded(try JSONDecoder().decode(Value.self, from: data))
        } catch {
            return .unreadable(keptAt: keepAside())
        }
    }

    public func save(_ value: Value) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        // Write the temporary file with the final permissions before the swap,
        // so a private file is never readable by others even for a moment.
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        do {
            _ = try fm.replaceItemAt(file, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Renames an unreadable file to "<name>.unreadable-<timestamp>" next to it.
    private func keepAside() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).unreadable-\(stamp)")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            return aside
        } catch {
            return nil
        }
    }
}
