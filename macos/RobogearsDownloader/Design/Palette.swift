import AppKit
import SwiftUI

/// The app's colours (DESIGN_DIRECTION 3.1). Every one lives in the asset
/// catalog with Light, Dark and Increase Contrast variants, so they follow
/// the appearance on their own. Only the main window's content area uses
/// them; chrome, sheets, Settings and alerts keep the system's colours.
enum Palette {
    /// Asset colours go through NSColor so AppKit resolves them in the
    /// drawing appearance, including the Increase Contrast variants.
    private static func named(_ name: String) -> Color { Color(nsColor: AppKit.named(name)) }

    /// Content background of the main window only: white in Light, pure
    /// black in Dark (the owner's identity).
    static let canvas = named("Canvas")
    /// Titles, played bars, the glyph. Stark black or white, not `labelColor`.
    static let ink = named("Ink")
    static let inkSecondary = named("InkSecondary")
    static let inkTertiary = named("InkTertiary")
    static let hairline = named("Hairline")
    /// Row hover and the summary notice.
    static let surface = named("Surface")
    /// Progress tracks.
    static let surface2 = named("Surface2")
    static let statusFailed = named("StatusFailed")
    static let statusSimilar = named("StatusSimilar")
    static let statusDone = named("StatusDone")
    static let waveUnplayed = named("WaveUnplayed")
    static let waveHoverMax = named("WaveHoverMax")
    static let waveCursor = named("WaveCursor")

    /// The same colours for AppKit drawing (the activity panel, the Dock tile).
    enum AppKit {
        static func named(_ name: String) -> NSColor { NSColor(named: name) ?? .labelColor }
        static var ink: NSColor { named("Ink") }
        static var inkSecondary: NSColor { named("InkSecondary") }
        static var inkTertiary: NSColor { named("InkTertiary") }
        static var statusFailed: NSColor { named("StatusFailed") }
        static var statusSimilar: NSColor { named("StatusSimilar") }
        static var statusDone: NSColor { named("StatusDone") }
        static var canvas: NSColor { named("Canvas") }
    }
}

/// What a status means, mapped to its one colour (colour is never the only
/// signal: every tone is paired with a symbol and words).
enum Tone: Equatable, Sendable {
    case ink, secondary, tertiary, failed, similar, done

    var color: Color {
        switch self {
        case .ink: Palette.ink
        case .secondary: Palette.inkSecondary
        case .tertiary: Palette.inkTertiary
        case .failed: Palette.statusFailed
        case .similar: Palette.statusSimilar
        case .done: Palette.statusDone
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ink: Palette.AppKit.ink
        case .secondary: Palette.AppKit.inkSecondary
        case .tertiary: Palette.AppKit.inkTertiary
        case .failed: Palette.AppKit.statusFailed
        case .similar: Palette.AppKit.statusSimilar
        case .done: Palette.AppKit.statusDone
        }
    }
}
