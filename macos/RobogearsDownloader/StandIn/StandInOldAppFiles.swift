import Foundation
import RobogearsCore

// TEMPORARY (see StandIn.swift): the previous version's files, for the debug
// instruments only. The running app uses RobogearsCore's LegacyElectronFiles
// (AppModel.live()).

/// Sample old files for the snapshot harness and `--run-checks`. It never
/// touches the disk: it doesn't look in the old folder, and Move to Trash and
/// Delete Old Sign-in only pretend, so an instrument run can never move or
/// delete the person's files. `folder` is shown in the notice's text and is
/// never read.
struct StandInOldAppFiles: OldAppFilesProviding {
    static let signInFileName = LegacyElectronFiles.signInFileName

    var folder: URL = AppPaths.legacyElectronDirectory()
    /// The names to report as present (none by default).
    var sampleItems: [String] = []

    func presentItems() -> [URL] { sampleItems.map { folder.appendingPathComponent($0) } }

    var shouldOfferNotice: Bool { !sampleItems.isEmpty }

    var hasOldSignIn: Bool { sampleItems.contains(Self.signInFileName) }

    /// Pretends: reports what the real type would move, moves nothing.
    @discardableResult func moveToTrash() throws -> [URL] { presentItems() }

    /// Pretends: the real type deletes token.json; this one leaves it.
    func deleteOldSignIn() throws {}
}
