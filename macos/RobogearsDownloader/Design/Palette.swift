import AppKit
import SwiftUI

/// The app's colours (DESIGN_DIRECTION 3.1). Every one lives in the asset
/// catalog with Light, Dark and Increase Contrast variants, so they follow
/// the appearance on their own. The main window's content area uses them;
/// chrome, sheets, Settings and alerts keep the system's colours, except
/// that error text everywhere is StatusFailed (system red is under 4.5:1).
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
        /// The asset colour, resolved by AppKit in the drawing appearance (so
        /// the person's Increase Contrast setting picks the high-contrast
        /// variants). Only when the snapshot harness renders an Increase
        /// Contrast look does it come from `IncreasedContrastTable` instead.
        static func named(_ name: String) -> NSColor {
            let asset = NSColor(named: name) ?? .labelColor
            guard let variants = IncreasedContrastTable.colors[name] else { return asset }
            return NSColor(name: name) { appearance in
                guard IncreasedContrastTable.isForced else { return asset }
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return dark ? variants.dark : variants.light
            }
        }
        static var ink: NSColor { named("Ink") }
        static var inkSecondary: NSColor { named("InkSecondary") }
        static var inkTertiary: NSColor { named("InkTertiary") }
        static var statusFailed: NSColor { named("StatusFailed") }
        static var statusSimilar: NSColor { named("StatusSimilar") }
        static var statusDone: NSColor { named("StatusDone") }
        static var canvas: NSColor { named("Canvas") }
    }
}

extension View {
    /// The main window's prominent buttons (Download All, + Add): the system
    /// `.borderedProminent` control, filled with the ink (black in Light,
    /// white in Dark) whatever accent the person chose. Under a chosen accent
    /// the system would fill it with that accent: with blue, a bright capsule
    /// whose white label is about 4:1, under DESIGN_DIRECTION 7's 4.5:1 floor
    /// for the prominent button, and a second accent beside the ink (owner's
    /// Debug build, 26 Oct). Pair it with `inkProminentLabel()` on the label.
    func inkProminent() -> some View {
        buttonStyle(.borderedProminent).tint(Palette.ink)
    }

    /// The label of an `inkProminent()` button: the canvas colour on the ink
    /// fill (21:1) while the window is in front and the button is available.
    /// Otherwise the system draws the button unfilled and the label keeps the
    /// system's own colour. Set on the label itself, so it never reaches the
    /// button's fill.
    func inkProminentLabel() -> some View { modifier(InkProminentLabel()) }
}

struct InkProminentLabel: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.isEnabled) private var isEnabled

    /// The canvas colour only on the ink fill: an unfilled button (window
    /// not in front, or unavailable) with a canvas label would be white on
    /// white in Light.
    static func usesCanvas(appearsActive: Bool, isEnabled: Bool) -> Bool { appearsActive && isEnabled }

    func body(content: Content) -> some View {
        if Self.usesCanvas(appearsActive: appearsActive, isEnabled: isEnabled) {
            content.foregroundStyle(Palette.canvas)
        } else {
            content
        }
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

/// The asset catalog's Increase Contrast variants, for the snapshot harness
/// only. AppKit picks those variants when the person's Increase Contrast
/// setting is on, and an off-screen window can't turn that on (an
/// `NSAppearance` named `.accessibilityHighContrastAqua` resolves as plain
/// Aqua), so the harness forces these. `--run-checks` compares every value
/// with the colour sets' Contents.json so the two can't drift apart.
enum IncreasedContrastTable {
    struct Variants {
        let light: NSColor
        let dark: NSColor
        let lightHex: String
        let darkHex: String
        let alpha: CGFloat

        init(_ lightHex: String, _ darkHex: String, alpha: CGFloat = 1) {
            self.lightHex = lightHex
            self.darkHex = darkHex
            self.alpha = alpha
            light = NSColor(hex: lightHex, alpha: alpha)
            dark = NSColor(hex: darkHex, alpha: alpha)
        }
    }

    /// Set only by the snapshot harness, on the main thread, between renders.
    nonisolated(unsafe) static var isForced = false

    /// DESIGN_DIRECTION 3.1, "Light + Increase Contrast" and "Dark + Increase Contrast".
    static let colors: [String: Variants] = [
        "Canvas": Variants("FFFFFF", "000000"),
        "Ink": Variants("000000", "FFFFFF"),
        "InkSecondary": Variants("3D3D3D", "C8C8C8"),
        "InkTertiary": Variants("595959", "9A9A9A"),
        "Hairline": Variants("8A8A8A", "5E5E5E"),
        "Surface": Variants("EBEBEB", "1A1A1A"),
        "Surface2": Variants("D6D6D6", "2E2E2E"),
        "StatusFailed": Variants("9B1C1C", "FF8A8A"),
        "StatusSimilar": Variants("7A5200", "FCD34D"),
        "StatusDone": Variants("0F5E27", "86EFAC"),
        "WaveUnplayed": Variants("000000", "FFFFFF", alpha: 0.45),
        "WaveHoverMax": Variants("000000", "FFFFFF", alpha: 0.80),
        "WaveCursor": Variants("000000", "FFFFFF", alpha: 0.80),
    ]
}

extension NSColor {
    /// "3D3D3D" in sRGB.
    convenience init(hex: String, alpha: CGFloat = 1) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}
