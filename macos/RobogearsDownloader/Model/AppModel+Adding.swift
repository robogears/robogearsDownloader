import AppKit
import RobogearsCore
import UniformTypeIdentifiers

/// Adding tracks: the Add field, paste, drop and Import Tracklist…. One add
/// at a time (D4 4.18); adding works during a batch and new rows wait for the
/// next Download All (D4 4.12).
extension AppModel {
    /// Tracklists longer than this ask first (D4 4.8).
    nonisolated static let largeImportLines = 2_000

    // MARK: The Add field

    /// Return in the Add field.
    func submitAddField() {
        let text = addFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch AddInputKind.classify(text) {
        case .empty:
            return
        case .link:
            if beginAdd(.link(text), description: "tracks from this link") { addFieldText = "" }
        case .search(let query):
            beginSearch(query)
        }
    }

    /// ⌘L.
    func focusAddField() { focusAddFieldRequest += 1 }

    // MARK: Adds

    /// Starts an add, or explains why it can't start. Returns whether it started.
    @discardableResult
    func beginAdd(_ source: AddSource, description: String) -> Bool {
        guard adding == nil else {
            activity.add(.warning, "Another add is still running. Wait for it to finish or cancel it, then try again.")
            sounds.play(.warningHonk)
            return false
        }
        guard isSignedIn else {
            // Nothing is lost: the add waits for sign-in (D4 1.1).
            alert = .signInToContinue(PendingAdd(source: source, description: description))
            return false
        }
        adding = AddingState()
        addTask = Task { [weak self] in
            guard let self else { return }
            var collected: [QueueItem] = []
            var failure: String?
            var cappedName: String?
            var sourceName = "link"
            for await event in self.services.resolver.add(source) {
                switch event {
                case .progress(let done, let total):
                    self.adding?.done = done
                    self.adding?.total = total
                case .items(let items):
                    collected += items
                case .capped(let name):
                    cappedName = name
                case .failed(let message):
                    failure = message
                case .finished(let name):
                    sourceName = name
                }
            }
            self.finishAdd(collected, failure: failure, cappedName: cappedName, sourceName: sourceName,
                           cancelled: Task.isCancelled, source: source)
        }
        return true
    }

    /// Cancel on the adding cover (also Escape and ⌘.): keeps what's matched (D4 4.9).
    func cancelAdd() {
        addTask?.cancel()
    }

    private func finishAdd(_ items: [QueueItem], failure: String?, cappedName: String?, sourceName: String,
                           cancelled: Bool, source: AddSource) {
        let progress = adding
        adding = nil
        addTask = nil
        if let failure, items.isEmpty {
            activity.add(.failed, failure)
            announce(failure)
            sounds.play(.warningHonk)
            return
        }
        // Rows already in the queue aren't added twice.
        let existing = Set(rows.compactMap(\.item.tidalID))
        var seen = existing
        var fresh: [QueueItem] = []
        var duplicates = 0
        for item in items {
            if let id = item.tidalID {
                if seen.contains(id) { duplicates += 1; continue }
                seen.insert(id)
            }
            fresh.append(item)
        }
        let notFound = fresh.filter { if case .notOnTIDAL = $0.match { true } else { false } }.count
        let newRows = fresh.map(QueueRow.init(item:))
        let checking = settings.libraryFolder != nil
        for row in newRows where row.item.tidalID != nil { row.isCheckingLibrary = checking }
        appendRows(newRows)

        var sentence: String
        if cancelled, let progress, let total = progress.total {
            sentence = "Stopped matching after \(Formatting.count(progress.done)) of \(Formatting.count(total)). Added \(Formatting.tracks(fresh.count))"
        } else if cancelled {
            sentence = "Stopped adding. Added \(Formatting.tracks(fresh.count))"
        } else {
            sentence = "Added \(Formatting.tracks(fresh.count)) from \(sourceName)"
        }
        var extras: [String] = []
        if notFound > 0 { extras.append("\(Formatting.count(notFound)) not on TIDAL") }
        if duplicates > 0 { extras.append("\(Formatting.count(duplicates)) already in the queue") }
        if !extras.isEmpty { sentence += " (\(extras.joined(separator: ", ")))" }
        sentence += "."
        let kind: ActivityLog.Kind = {
            if case .tracklist = source { return .importList }
            return .added
        }()
        activity.add(kind, sentence)
        announce(sentence)

        if let cappedName {
            let message = "Spotify only shares the first 100 tracks of a playlist. If \(cappedName) is longer, export it with Exportify and drop the CSV here."
            activity.add(.warning, message)
            if batch == nil { summary = BatchSummary(outcome: .spotifyCap(message)) }
        }
        checkLibrary(for: newRows)
        checkDownloadFolder(for: newRows)
    }

    // MARK: Search

    func beginSearch(_ query: String) {
        guard adding == nil else {
            activity.add(.warning, "Another add is still running. Wait for it to finish or cancel it, then try again.")
            return
        }
        guard isSignedIn else {
            alert = .signInToContinue(PendingAdd(source: .line(query), description: "a search for “\(query)”"))
            return
        }
        adding = AddingState()
        addTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.services.resolver.search(query)
                guard !Task.isCancelled else { self.adding = nil; return }
                let results = await self.markLibrary(found)
                guard !Task.isCancelled else { self.adding = nil; return }
                self.adding = nil
                self.activity.add(.search, results.isEmpty
                                  ? "No TIDAL results for “\(query)”."
                                  : "Found \(Formatting.count(results.count)) TIDAL results for “\(query)”.")
                self.sheet = .searchResults(query: query, results: results)
            } catch {
                self.adding = nil
                let message = (error as? ServiceError)?.message ?? "TIDAL search didn't work. Try again."
                self.activity.add(.failed, message)
                self.sounds.play(.warningHonk)
            }
            self.addTask = nil
        }
    }

    /// Search TIDAL… on a "Not on TIDAL" or left-out row: pick-one mode.
    func searchTIDAL(for rowID: UUID) {
        guard let row = row(rowID), adding == nil else { return }
        let query = [row.item.originalTitle ?? row.item.title, row.item.originalArtist ?? row.item.artist]
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard isSignedIn else {
            alert = .signInToContinue(PendingAdd(source: .line(query), description: "a search for “\(query)”",
                                                 pickOneRowID: rowID))
            return
        }
        adding = AddingState()
        addTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.markLibrary((try? await self.services.resolver.search(query)) ?? [])
            self.adding = nil
            self.addTask = nil
            guard !Task.isCancelled else { return }
            self.sheet = .pickOne(rowID: rowID, query: query, results: results)
        }
    }

    /// Search results carry the queue's own library marks (D4 4.11), from
    /// the same check the queue uses. "In Queue" is read live by the sheet.
    func markLibrary(_ results: [SearchResult]) async -> [SearchResult] {
        guard settings.libraryFolder != nil, !results.isEmpty else { return results }
        let verdicts = await services.library.check(results.map(\.track))
        return results.map { result in
            var marked = result
            marked.track.libraryMatch = verdicts[result.track.id]?.match
            return marked
        }
    }

    func isInQueue(_ tidalID: Int64?) -> Bool {
        guard let tidalID else { return false }
        return rows.contains { $0.item.tidalID == tidalID }
    }

    /// Add Selected in the search sheet. A library-exact pick lands left out,
    /// as the queue rule says (D4 4.11).
    func addSearchResults(_ results: [SearchResult], query: String) {
        // A library-exact pick lands left out, as the queue rule says (D4 4.11).
        let items = results.map(\.track).filter { !isInQueue($0.tidalID) }.map { track in
            var item = track
            item.included = item.libraryMatch?.kind != .exact
            return item
        }
        guard !items.isEmpty else { return }
        let newRows = items.map(QueueRow.init(item:))
        appendRows(newRows)
        let sentence = "Added \(Formatting.tracks(newRows.count)) from a search for “\(query)”."
        activity.add(.added, sentence)
        announce(sentence)
        checkLibrary(for: newRows)
        checkDownloadFolder(for: newRows)
    }

    /// Use This Track in pick-one mode: the chosen track replaces the row in place.
    func replaceRow(_ rowID: UUID, with result: SearchResult) {
        guard let row = row(rowID) else { return }
        let old = row.item
        let t = result.track
        row.item = QueueItem(id: old.id, tidalID: t.tidalID, title: t.title, version: t.version, artist: t.artist,
                             album: t.album, durationSeconds: t.durationSeconds, isrc: t.isrc, hiRes: t.hiRes,
                             explicit: t.explicit, source: old.source,
                             originalTitle: old.originalTitle ?? old.title, originalArtist: old.originalArtist ?? old.artist,
                             match: .matched, libraryMatch: t.libraryMatch, included: nil, state: .waiting)
        row.preview = .none
        queueDidChange()
        activity.add(.search, "Matched \(old.title) to \(t.title) — \(t.artist).")
        checkLibrary(for: [row])
        enqueuePreload(row.id)
    }

    // MARK: Sign in to continue

    func continueAfterSignIn(_ pending: PendingAdd?) {
        guard let pending else { return }
        if let rowID = pending.pickOneRowID {
            searchTIDAL(for: rowID)
            return
        }
        switch pending.source {
        case .line(let text) where AddInputKind.classify(text) != .link && !Self.hasSeparator(text):
            beginSearch(text)
        default:
            beginAdd(pending.source, description: pending.description)
        }
    }

    // MARK: Paste (D4 4.7)

    /// ⌘V with no text field focused, main window only.
    func paste(_ providers: [NSItemProvider]) {
        guard !isModalUp else { return }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            loadFileURLs(fileProviders) { [weak self] urls in self?.importFiles(urls) }
            return
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String else { return }
            Task { @MainActor in self?.pasteText(text) }
        }
    }

    func pasteText(_ raw: String) {
        let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        if lines.count > 1 {
            importText(raw, name: nil)
            return
        }
        let line = lines[0]
        if AddInputKind.classify(line) == .link {
            beginAdd(.link(line), description: "tracks from the pasted link")
        } else if Self.hasSeparator(line) {
            beginAdd(.line(line), description: "1 track from pasted text")
        } else {
            // One bare name goes to the field, ready for Return.
            addFieldText = line
            focusAddField()
        }
    }

    static func hasSeparator(_ line: String) -> Bool {
        [" - ", " – ", " — ", " | ", "\t", ", "].contains { line.contains($0) }
    }

    // MARK: Drop (D4 4.8)

    static let tracklistExtensions: Set<String> = ["csv", "txt", "tsv"]

    /// Whether a drag carries something the window accepts.
    static func acceptsDrop(_ providers: [NSItemProvider]) -> Bool {
        providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || $0.canLoadObject(ofClass: NSString.self)
        }
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !isModalUp, Self.acceptsDrop(providers) else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            loadFileURLs(files) { [weak self] urls in self?.importFiles(urls) }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) }) {
            _ = provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                guard let url = object as? URL else { return }
                let text = url.absoluteString
                Task { @MainActor in self?.dropText(text) }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) {
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                Task { @MainActor in self?.dropText(text) }
            }
            return true
        }
        return false
    }

    private func dropText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if AddInputKind.classify(trimmed) == .link, !trimmed.contains("\n") {
            let lower = trimmed.lowercased()
            if lower.contains("tidal.com") || lower.contains("spotify") {
                beginAdd(.link(trimmed), description: "tracks from the dropped link")
            } else {
                refuse("That link isn't from TIDAL or Spotify. Drop a TIDAL or Spotify link, or a CSV or text tracklist.")
            }
        } else {
            pasteText(trimmed)
        }
    }

    private func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = box.urls
            MainActor.assumeIsolated { completion(urls) }
        }
    }

    // MARK: Import Tracklist… (⌘O) and dropped files

    func showImportPanel() {
        guard adding == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Tracklist"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .tabSeparatedText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        var texts: [String] = []
        var names: [String] = []
        for url in urls {
            if let reason = Self.refusal(for: url) {
                refuse(reason)
                continue
            }
            guard let text = Self.readText(url) else {
                refuse("\(url.lastPathComponent) couldn't be read as text. Save it as UTF-8 CSV or text and drop it again.")
                continue
            }
            texts.append(text)
            names.append(url.deletingPathExtension().lastPathComponent)
        }
        guard !texts.isEmpty else { return }
        importText(texts.joined(separator: "\n"), name: names.count == 1 ? names[0] : "\(names.count) files")
    }

    private func importText(_ text: String, name: String?) {
        let lineCount = text.split(whereSeparator: \.isNewline).count
        if lineCount > Self.largeImportLines {
            alert = .largeImport(lines: lineCount, text: text, name: name)
            return
        }
        let description = name.map { "tracks from \($0)" } ?? "\(Formatting.tracks(lineCount)) from pasted text"
        beginAdd(.tracklist(text: text, name: name), description: description)
    }

    /// "Import the first 2,000?" → Import.
    func importFirstLines(_ text: String, name: String?) {
        let lines = text.split(whereSeparator: \.isNewline).prefix(Self.largeImportLines)
        beginAdd(.tracklist(text: lines.joined(separator: "\n"), name: name),
                 description: "the first \(Formatting.count(Self.largeImportLines)) tracks")
    }

    /// Why a dropped file is refused, in the app's voice; nil when accepted.
    static func refusal(for url: URL) -> String? {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "\(name) is a folder. Drop a CSV or text tracklist, or a TIDAL or Spotify link."
        }
        let ext = url.pathExtension.lowercased()
        if tracklistExtensions.contains(ext) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 20_000_000 ? "\(name) is too large to be a tracklist. Drop a CSV or text file under 20 MB." : nil
        }
        let type = UTType(filenameExtension: ext)
        let what: String
        if type?.conforms(to: .audio) == true { what = "an audio file" }
        else if type?.conforms(to: .image) == true { what = "an image" }
        else if type?.conforms(to: .movie) == true { what = "a video" }
        else { what = "not a tracklist" }
        return "\(name) is \(what). Drop a CSV or text tracklist, or a TIDAL or Spotify link."
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // TODO(core-input lane): the tracklist reader handles encodings and BOMs properly.
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    func refuse(_ reason: String) {
        activity.add(.warning, reason)
        announce(reason)
        sounds.play(.warningHonk)
    }

    // MARK: Library and download-folder checks (D4 4.20, 2.16)

    func checkLibrary(for targets: [QueueRow]) {
        let candidates = targets.filter { $0.item.tidalID != nil }
        guard settings.libraryFolder != nil, !candidates.isEmpty else {
            for row in candidates { row.isCheckingLibrary = false }
            return
        }
        for row in candidates { row.isCheckingLibrary = true }
        let items = candidates.map(\.item)
        Task {
            let verdicts = await services.library.check(items)
            let matches = verdicts.mapValues(\.match)
            var changed = false
            for row in candidates {
                guard self.row(row.id) != nil else { continue }
                row.isCheckingLibrary = false
                row.libraryDurationSeconds = verdicts[row.id]?.durationSeconds
                let match = matches[row.id]
                if row.item.libraryMatch != match {
                    row.item.libraryMatch = match
                    // An exact match starts left out; the person's own choice is kept otherwise.
                    if match?.kind == .exact, row.item.included { row.item.included = false }
                    changed = true
                }
            }
            if changed { queueDidChange() }
            let exact = candidates.filter { matches[$0.id]?.kind == .exact }.count
            let similar = candidates.filter { matches[$0.id]?.kind == .similar }.count
            if exact + similar > 0 {
                var parts: [String] = []
                if exact > 0 { parts.append("\(Formatting.tracks(exact)) already in your library (left out)") }
                if similar > 0 { parts.append("\(Formatting.count(similar)) with a similar version") }
                activity.add(.library, "Library check: " + parts.joined(separator: ", ") + ".")
            }
        }
    }

    func checkDownloadFolder(for targets: [QueueRow]) {
        guard let reference = settings.downloadFolder,
              case .available(let folder) = Folders.status(of: reference, requireWritable: false) else { return }
        let items = targets.filter { $0.item.tidalID != nil }.map(\.item)
        guard !items.isEmpty else { return }
        Task {
            for item in items where await services.library.isInDownloadFolder(item, folder: folder) {
                self.row(item.id)?.inDownloadFolder = true
            }
        }
    }
}

/// Collects URLs from item-provider callbacks (any thread) for the main actor.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}
