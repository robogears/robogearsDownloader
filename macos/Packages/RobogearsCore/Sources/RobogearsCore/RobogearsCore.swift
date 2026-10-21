// Shared constants for the core module.
//
// Folder layout (one folder per area, so parallel work never touches the
// same file):
//   Input/     links typed or pasted, CSV and plain-text tracklists
//   Text/      normalising, file-name sanitising, percent-encoding
//   Matching/  TIDAL matcher and library matcher
//   TIDAL/     models, manifests, API client, sign-in, token keeper, retries
//   Spotify/   public embed page parsing
//   Library/   folder walk, tag reader, saved index
//   Download/  per-track pipeline and the FLAC writer
//   Update/    version compare and the GitHub release check
//   Audio/     waveform peaks and sound effects

public enum RobogearsCore {
    /// The app's marketing version. Kept in step with the Xcode project
    /// (MARKETING_VERSION in macos/project.yml).
    public static let version = "0.1.31"

    /// The GitHub repository releases are published from. The v0.1.30
    /// Electron updater reads `/releases/latest` from the same place.
    public static let releasesRepository = "robogears/robogearsDownloader"
}
