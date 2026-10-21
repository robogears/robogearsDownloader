# robogears Downloader — native macOS app

The Swift rewrite of the Electron app at the repository root. The Electron code stays in place as the reference until the Swift app replaces it; [docs/electron-reference/](../docs/electron-reference/README.md) describes it.

- `project.yml` — XcodeGen spec for the app (`robogears Downloader`, `com.robogears.downloader`, macOS 15+).
- `RobogearsDownloader/` — the app target: windows, menus and drawing only.
- `Packages/RobogearsCore/` — every rule that doesn't need a window, with its tests.

## Build and test

```bash
cd macos && xcodegen generate
```

```bash
cd macos/Packages/RobogearsCore && swift test
```

```bash
cd macos && xcodebuild -project RobogearsDownloader.xcodeproj -scheme RobogearsDownloader -configuration Debug -derivedDataPath build/DerivedData build
```

The generated `RobogearsDownloader.xcodeproj` is committed so the project opens without XcodeGen; regenerate it after editing `project.yml`.
