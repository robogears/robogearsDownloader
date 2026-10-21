import CoreGraphics
import SwiftUI

/// Spacing, sizes and durations (DESIGN_DIRECTION 3.3 and 3.5). One place, so
/// the pixel checks in section 7 have one number to compare against.
enum Metrics {
    // Window
    static let windowDefault = CGSize(width: 980, height: 740)
    static let windowMinimum = CGSize(width: 720, height: 540)
    /// Side inset of the content regions; rows align their content to it.
    static let contentInset: CGFloat = 20
    static let regionGap: CGFloat = 12

    // Rows: 28 pt tall, 1 pt above and below (30 pt pitch), 44 pt with a second line.
    static let rowHeight: CGFloat = 28
    static let rowHeightTwoLines: CGFloat = 44
    static let rowInsetVertical: CGFloat = 1
    static let rowInsetHorizontal: CGFloat = 8
    /// The list sits this far in from the window edge so row content (after
    /// the table's own 8 pt cell inset and the row's 8 pt inset) lines up
    /// with the 20 pt content inset. Measured from a render, 21 Oct 2026.
    static let listSideInset: CGFloat = contentInset - rowInsetHorizontal - 8
    static let gapAfterPlay: CGFloat = 8
    static let gapAroundWaveform: CGFloat = 10
    static let gapArtistToBadge: CGFloat = 10
    static let gapStatusToAction: CGFloat = 8
    static let gapBeforeRemove: CGFloat = 8

    static let waveformHeight: CGFloat = 22
    static let playVisible: CGFloat = 20
    static let playHit: CGFloat = 24
    static let playGlyph: CGFloat = 10
    static let removeHit: CGFloat = 20
    static let removeGlyph: CGFloat = 11
    static let artistMinWidth: CGFloat = 80
    static let artistMaxWidth: CGFloat = 220
    static let statusMaxWidth: CGFloat = 200
    static let explicitMark: CGFloat = 12
    static let progressLine: CGFloat = 2

    // Toolbar
    static let addFieldMin: CGFloat = 320
    static let addFieldMax: CGFloat = 560

    /// The Add field grows with the window: 320 pt at the minimum width,
    /// 560 pt once the window is wide enough, never pushing Download All or
    /// the update control into the overflow menu.
    static func addFieldWidth(forWindowWidth width: CGFloat) -> CGFloat {
        min(addFieldMax, max(addFieldMin, width - 400))
    }

    // Regions
    static let addAreaHeight: CGFloat = 28
    static let headerHeight: CGFloat = 28
    static let volumeWidth: CGFloat = 80
    static let noticeHeight: CGFloat = 44
    static let noticeRadius: CGFloat = 6
    static let activityDefault: CGFloat = 160
    static let activityMinimum: CGFloat = 72
    static let activityHeader: CGFloat = 24
    static let emptyMaxWidth: CGFloat = 420
    static let glyph: CGFloat = 56
    static let dropBoxRadius: CGFloat = 8
    static let dropBoxPadding: CGFloat = 16
    static let dragOutline: CGFloat = 2
    static let dragOutlineRadius: CGFloat = 6

    // Activity lines
    static let activityMaxLines = 2_000
}

/// Motion (DESIGN_DIRECTION 3.5). Every animation is brief, eases out and
/// disappears under Reduce Motion.
enum Motion {
    static let hover = 0.12
    static let removal = 0.15
    static let progress = 0.15
    static let numbers = 0.2
    static let symbol = 0.2
    static let fadeIn = 0.2
    static let cover = 0.15
    static let loadingLineInterval: TimeInterval = 2.5

    /// The animation to use, or none under Reduce Motion.
    static func ease(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    static func linear(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: duration)
    }
}
