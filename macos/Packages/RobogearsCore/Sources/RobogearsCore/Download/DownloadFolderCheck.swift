// The download folder, checked before each track (decision 4, item 2.19).
//
// The batch hands each track the folder it started with (2.17). Before any
// TIDAL request, the folder must still be there, be a folder, be writable
// and not be in the Trash. The Electron app re-created a missing folder
// with `mkdir -p` for every track, so a renamed folder silently became a
// new, empty one and an unplugged drive failed every track
// (download-pipeline.md B4 step 5). Here the folder is never created.
import Foundation

enum DownloadFolderCheck {
    /// The problem with `folder` in the app's words (what's wrong and what
    /// to do, worded as `Folders.message` words it for Settings), or nil
    /// when downloads can be saved there.
    static func problem(with folder: URL, trashDirectories: [URL]) -> String? {
        let fm = FileManager.default
        let name = "“\(folder.lastPathComponent)”"
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if let volume = Folders.volumeRoot(of: folder.path), !fm.fileExists(atPath: volume) {
                let disk = URL(fileURLWithPath: volume).lastPathComponent
                return "The download folder \(name) on \(disk) isn't available. Connect the drive or choose another folder."
            }
            return "The download folder \(name) no longer exists. Create it again or choose another folder."
        }
        if Folders.isInside(folder, anyOf: trashDirectories) {
            return "The download folder \(name) is in the Trash. Put it back or choose another folder."
        }
        if !fm.isWritableFile(atPath: folder.path) {
            return "robogears Downloader can't save into the download folder \(name). Check its permissions or choose another folder."
        }
        return nil
    }

    /// For a disk that gives no temporary folder (2.2's live check: some
    /// external or network disks may not). Every remaining track would hit
    /// it, so it stops the batch once, like the other folder problems.
    static func noTemporaryFolderMessage(for folder: URL) -> String {
        noTemporaryFolderMessage(for: folder, isDriveRoot: isDriveRoot(folder))
    }

    /// A download folder at the top level of a drive gets macOS's temporary
    /// folder for that drive inside it, which 2.2 refuses (nothing half-done
    /// may sit in the download folder or below it). A folder on the same
    /// drive works, so the message says that rather than "another disk".
    static func noTemporaryFolderMessage(for folder: URL, isDriveRoot: Bool) -> String {
        let name = "“\(folder.lastPathComponent)”"
        if isDriveRoot {
            return "Downloads can't be saved at the top level of \(name). Create a folder on the drive and choose that instead."
        }
        return "The disk with the download folder \(name) doesn't allow the temporary files a download needs. Choose a folder on another disk."
    }

    /// True when `folder` is the top level of a disk.
    static func isDriveRoot(_ folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }
}
