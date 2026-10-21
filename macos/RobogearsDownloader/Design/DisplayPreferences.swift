import SwiftUI

/// Increase Contrast, Reduce Motion and Reduce Transparency, resolved once at
/// the top of each window so every view reads one value. The snapshot
/// harness sets overrides because an off-screen window can't change the
/// person's accessibility settings (only its appearance).
struct DisplayPreferences: Equatable, Sendable {
    var increasedContrast = false
    var reduceMotion = false
    var reduceTransparency = false
}

struct DisplayOverrides: Equatable, Sendable {
    var increasedContrast: Bool?
    var reduceMotion: Bool?
    var reduceTransparency: Bool?
}

extension EnvironmentValues {
    @Entry var displayPreferences = DisplayPreferences()
    @Entry var displayOverrides = DisplayOverrides()
}

private struct ResolveDisplayPreferences: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayOverrides) private var overrides

    func body(content: Content) -> some View {
        content.environment(\.displayPreferences, DisplayPreferences(
            increasedContrast: overrides.increasedContrast ?? (contrast == .increased),
            reduceMotion: overrides.reduceMotion ?? reduceMotion,
            reduceTransparency: overrides.reduceTransparency ?? reduceTransparency))
    }
}

extension View {
    /// Applied at the root of every window.
    func resolvingDisplayPreferences() -> some View { modifier(ResolveDisplayPreferences()) }
}
