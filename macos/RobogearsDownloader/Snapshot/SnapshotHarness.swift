import AppKit
import RobogearsCore
import SwiftUI

/// A debug instrument, never shipped behaviour a person sees: with
/// `--render-snapshots <dir>` the app renders its main-window states (and,
/// through SnapshotWindows, every sheet, alert, Settings pane, About and the
/// Dock tile) into
/// PNGs at 2× from off-screen windows (no window is ever shown, nothing is
/// saved, nothing is loaded) and quits. Used to check the real pixels in
/// Light, Dark and both Increase Contrast appearances.
@MainActor
enum SnapshotHarness {
    static func requestedDirectory(_ arguments: [String]) -> URL? {
        guard let i = arguments.firstIndex(of: "--render-snapshots") else { return nil }
        let path = i + 1 < arguments.count ? arguments[i + 1] : FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    struct Look {
        var name: String
        var appearance: NSAppearance.Name
        var overrides: DisplayOverrides

        static let light = Look(name: "light", appearance: .aqua, overrides: .init(increasedContrast: false))
        static let dark = Look(name: "dark", appearance: .darkAqua, overrides: .init(increasedContrast: false))
        static let lightHC = Look(name: "light-ic", appearance: .accessibilityHighContrastAqua, overrides: .init(increasedContrast: true))
        static let darkHC = Look(name: "dark-ic", appearance: .accessibilityHighContrastDarkAqua, overrides: .init(increasedContrast: true))
        static let all = [light, dark, lightHC, darkHC]
    }

    static let large = CGSize(width: 980, height: 740)
    static let small = CGSize(width: 720, height: 540)

    static func run(into directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Can't create \(directory.path): \(error.localizedDescription)\n".utf8))
            StorageLocation.removeInstrumentFolder()
            exit(1)
        }
        var written: [String] = []
        // "--only <prefix>" renders just the scenarios whose name starts with it.
        let only = CommandLine.arguments.firstIndex(of: "--only").flatMap {
            $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
        }
        for scenario in SnapshotScenarios.all() where only.map({ scenario.name.hasPrefix($0) }) ?? true {
            let started = Date()
            for look in scenario.looks {
                for size in scenario.sizes {
                    let name = "\(scenario.name)-\(look.name)-\(Int(size.width))x\(Int(size.height)).png"
                    let model = scenario.makeModel()
                    var overrides = look.overrides
                    if scenario.reduceTransparency { overrides.reduceTransparency = true }
                    overrides.reduceMotion = true
                    let url = directory.appendingPathComponent(name)
                    if render(model: model, size: size, look: look, overrides: overrides,
                              hover: scenario.hover(model), to: url) {
                        written.append(url.path)
                    }
                }
            }
            FileHandle.standardError.write(Data(String(format: "%@: %.1f s\n", scenario.name, Date().timeIntervalSince(started)).utf8))
        }
        // Sheets, alerts, Settings, About and the Dock tile.
        written += SnapshotWindows.renderAll(into: directory, only: only)
        print(written.joined(separator: "\n"))
        StorageLocation.removeInstrumentFolder()
        exit(written.isEmpty ? 1 : 0)
    }

    /// Renders the main window (title bar, toolbar and content) at 2×.
    private static func render(model: AppModel, size: CGSize, look: Look, overrides: DisplayOverrides,
                               hover: SnapshotHover?, to url: URL) -> Bool {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look.appearance)
        window.title = "robogears Downloader"
        window.toolbarStyle = .unified

        // Increase Contrast: AppKit picks the asset catalog's high-contrast
        // colours only when the system setting is on (the accessibility
        // appearance names resolve as plain Aqua off-screen), so the harness
        // forces the same values from IncreasedContrastTable, which
        // --run-checks keeps equal to the colour sets. The overrides switch on
        // the contrast-specific code too (no dimming, stronger bars).
        IncreasedContrastTable.isForced = overrides.increasedContrast == true
        defer { IncreasedContrastTable.isForced = false }
        let root = MainWindow(model: model)
            .environment(\.displayOverrides, overrides)
            .environment(\.snapshotHover, hover)
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.setContentSize(size)

        // Let SwiftUI and AppKit lay out (lists fill their rows on layout passes).
        for _ in 0..<8 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        // The window is never key (the app never activates, so it can't take
        // focus from the person), and AppKit draws a window's active look
        // only when it really is key: selection draws in its inactive grey,
        // and prominent buttons without their fill. Section 7's first two
        // checks (the selection and the prominent button in a window in
        // front) stay live checks.

        let target = host.superview ?? host
        let bounds = target.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = bounds.size
        NSAppearance(named: look.appearance)?.performAsCurrentDrawingAppearance {
            target.cacheDisplay(in: bounds, to: rep)
        }
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("Can't write \(url.path): \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
