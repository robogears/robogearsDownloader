import Testing
@testable import RobogearsCore

@Test func versionMatchesTheReleaseSeries() {
    // GitHub has v0.1.30 (the last Electron release); the Swift app continues
    // the series, so its first version must compare newer than 0.1.30.
    #expect(RobogearsCore.version == "0.1.31")
}

@Test func releasesComeFromTheOriginalRepository() {
    #expect(RobogearsCore.releasesRepository == "robogears/robogearsDownloader")
}
