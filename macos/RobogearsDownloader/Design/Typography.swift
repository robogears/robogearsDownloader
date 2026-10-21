import SwiftUI

/// Type roles (DESIGN_DIRECTION 3.2). SF Pro throughout at the macOS sizes
/// (body 13, callout 12, subheadline 11, caption2 10); SF Mono only in the
/// activity panel and for links and codes. No light weights, nothing below 10 pt.
enum Typography {
    static let rowTitle = Font.body.weight(.medium)
    static let edition = Font.body
    static let artist = Font.callout.monospacedDigit()
    static let status = Font.callout.monospacedDigit()
    static let secondLine = Font.subheadline
    static let badge = Font.caption2.weight(.medium)
    static let explicitMark = Font.system(size: 9, weight: .bold)
    static let queueHeader = Font.headline
    static let queueCount = Font.body
    static let counter = Font.callout.monospacedDigit()
    static let hint = Font.callout
    static let emptyTitle = Font.title3.weight(.semibold)
    static let emptyBody = Font.body
    static let notice = Font.body
    static let activityHeader = Font.subheadline
    static let coverText = Font.body.monospacedDigit()
    /// The activity panel's lines, 12 pt monospaced.
    static let activityPointSize: CGFloat = 12
}
