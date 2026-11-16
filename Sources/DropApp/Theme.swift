import AppKit
import SwiftUI

/// Sizes, spacing and colours from the approved design boards (`.claude/canvas/project`).
/// Colours are system colours so light and dark mode and the user's accent follow macOS;
/// only the layout numbers are fixed, and they live here rather than in the views.
enum Theme {
    /// The install panel's content inset, the same on all four sides (every panel board).
    static let panelInset: CGFloat = 18
    /// The onboarding window's content inset on the left, right and bottom (boards
    /// Onboarding1 to Onboarding5); the top is the title bar band.
    static let onboardingInset: CGFloat = 24

    /// The panel card (boards 1-3, Update, Warning, Fallback, Password, Licence).
    enum Panel {
        static let width: CGFloat = 400
        static let spacing: CGFloat = 16
        /// The Licence board packs its taller content a little closer.
        static let licenceSpacing: CGFloat = 14
        static let cornerRadius: CGFloat = 18
        /// The board's card is `rgba(255,255,255,0.92)`: the popover material with the
        /// control background over it comes out the same in light mode and stays dark in dark.
        static let tintOpacity: Double = 0.7
        static let borderOpacity: Double = 0.6
        /// Space between the menu bar and the panel when it drops from the icon, and from
        /// the screen edge when it falls back to the top right.
        static let screenGap: CGFloat = 6
        static let screenMargin: CGFloat = 8
    }

    enum Icon {
        static let size: CGFloat = 60
        static let cornerRadius: CGFloat = 14
        static let licenceSize: CGFloat = 48
        static let licenceCornerRadius: CGFloat = 12
        static let glyph: CGFloat = 30
        static let licenceGlyph: CGFloat = 26
        static let titleSpacing: CGFloat = 14
        /// The green check on board 3's icon.
        static let badge: CGFloat = 24
        static let badgeBorder: CGFloat = 2
        static let badgeOffset: CGFloat = 6
        static let badgeGlyph: CGFloat = 11
        /// Settings' Recent list and the menu's Recently installed rows.
        static let recentSize: CGFloat = 22
        static let recentCornerRadius: CGFloat = 6
        static let menuSize: CGFloat = 18
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let licenceTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let subtitle = SwiftUI.Font.system(size: 12)
        static let body = SwiftUI.Font.system(size: 13)
        static let small = SwiftUI.Font.system(size: 12)
        static let smallStrong = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 11)
        static let calloutTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let button = SwiftUI.Font.system(size: 13)
        static let primaryButton = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Title tracking: -0.01em of 17 pt.
        static let titleTracking: CGFloat = -0.17
    }

    /// The tinted boxes: signer, steps, trash notice, warnings.
    enum Card {
        static let verticalPadding: CGFloat = 10
        static let horizontalPadding: CGFloat = 12
        static let warningPadding: CGFloat = 12
        static let cornerRadius: CGFloat = 10
        static let rowSpacing: CGFloat = 8
        static let iconSpacing: CGFloat = 8
        static let calloutSpacing: CGFloat = 10
        static let rowIcon: CGFloat = 14
        static let calloutIcon: CGFloat = 16
        static let warningIcon: CGFloat = 18
        /// `rgba(0,0,0,0.035)` on the boards; `primary` so it lightens in dark mode.
        static let fillOpacity: Double = 0.035
        static let darkFillOpacity: Double = 0.07
        static let warningFillOpacity: Double = 0.14
        static let lineSpacing: CGFloat = 2.5
    }

    enum Button {
        static let height: CGFloat = 30
        static let secondaryPadding: CGFloat = 14
        static let primaryPadding: CGFloat = 18
        static let licencePrimaryPadding: CGFloat = 16
        static let cornerRadius: CGFloat = 8
        static let spacing: CGFloat = 8
        static let borderOpacity: Double = 0.12
        static let pressedOpacity: Double = 0.8
    }

    enum Header {
        static let spacing: CGFloat = 6
        static let icon: CGFloat = 11
    }

    enum Progress {
        static let height: CGFloat = 6
        static let spacing: CGFloat = 8
        static let trackOpacity: Double = 0.08
    }

    enum Licence {
        static let textHeight: CGFloat = 250
        static let textPadding: CGFloat = 12
        static let textCornerRadius: CGFloat = 8
    }

    enum Password {
        static let fieldBorder: CGFloat = 2
        static let fieldCornerRadius: CGFloat = 7
        static let fieldVerticalPadding: CGFloat = 6
        static let fieldHorizontalPadding: CGFloat = 10
        static let spacing: CGFloat = 6
    }

    enum Settings {
        static let width: CGFloat = 600
        static let rowSpacing: CGFloat = 10
    }

    /// The onboarding window (boards Onboarding1 to Onboarding5).
    enum Onboarding {
        static let width: CGFloat = 600
        static let height: CGFloat = 480
        /// The boards' title bar band; never less than the real title bar, which is read.
        static let titleBand: CGFloat = 44
        static let artHeight: CGFloat = 190
        static let artCornerRadius: CGFloat = 12
        static let textTopPadding: CGFloat = 22
        static let textHorizontalPadding: CGFloat = 48
        static let textSpacing: CGFloat = 8
        static let bodyMaxWidth: CGFloat = 420
        /// Line height 1.5 on 13 pt: 19.5 pt less the font's own 16 pt line (measured), split
        /// between lines and, halved, above and below the paragraph as CSS does.
        static let bodyLineSpacing: CGFloat = 3.5
        /// The info line sits a little further below the body than the body below the title.
        static let infoTopPadding: CGFloat = 6
        static let infoIconSpacing: CGFloat = 6
        static let bylineTopPadding: CGFloat = 10
        static let footerSpacing: CGFloat = 12
        static let linkPadding: CGFloat = 6
        static let dot: CGFloat = 6
        static let activeDotWidth: CGFloat = 18
        static let dotSpacing: CGFloat = 6
        /// `#D1D1D6` dots and placeholder bars: primary at this opacity in both modes.
        static let mutedOpacity: Double = 0.18
        /// `#E5E5EA` tiles and the off switch.
        static let faintOpacity: Double = 0.1
        static let hairlineOpacity: Double = 0.08
        static let rowDividerOpacity: Double = 0.06
        static let shadowOpacity: Double = 0.1
        static let shadowRadius: CGFloat = 9
        static let shadowY: CGFloat = 6

        static let titleFont = SwiftUI.Font.system(size: 22, weight: .bold)
        /// -0.01em of 22 pt.
        static let titleTracking: CGFloat = -0.22
        static let infoFont = SwiftUI.Font.system(size: 11)
        /// Board 5's byline: 12 pt, secondary label colour, so it stays readable (4.5:1).
        static let bylineFont = SwiftUI.Font.system(size: 12)
        static let infoIcon: CGFloat = 12
        static let linkFont = SwiftUI.Font.system(size: 12)

        /// The drawings, in the boards' SVG units (1 unit = 1 pt).
        enum Art {
            /// Board 1: disk image, arrow, Applications folder.
            static let diskImage: CGFloat = 72
            static let glyphStroke: CGFloat = 2
            static let largeDiskImage: CGFloat = 88
            static let arrowWidth: CGFloat = 48
            static let arrowHeight: CGFloat = 20
            static let arrowStroke: CGFloat = 2.6
            static let rowSpacing: CGFloat = 22
            static let diskImageLabel = SwiftUI.Font.system(size: 12, weight: .bold)
            /// Board 2: the menu bar and the panel dropping from it.
            static let menuBarWidth: CGFloat = 300
            static let menuBarHeight: CGFloat = 22
            static let menuBarRadius: CGFloat = 6
            static let menuBarPadding: CGFloat = 10
            static let menuIconWidth: CGFloat = 18
            static let menuIconHeight: CGFloat = 14
            static let menuIconRadius: CGFloat = 4
            static let menuIconRing: CGFloat = 2
            static let menuIconGlyph: CGFloat = 9
            static let menuItemWidth: CGFloat = 30
            static let bar: CGFloat = 6
            static let thinBar: CGFloat = 5
            static let panelWidth: CGFloat = 200
            static let panelRadius: CGFloat = 10
            static let panelPadding: CGFloat = 10
            static let panelSpacing: CGFloat = 8
            static let panelTile: CGFloat = 28
            static let panelTileRadius: CGFloat = 7
            static let panelLineSpacing: CGFloat = 4
            static let panelTitleWidth: CGFloat = 60
            static let panelSubtitleWidth: CGFloat = 90
            static let panelButtonWidth: CGFloat = 40
            static let panelButtonHeight: CGFloat = 16
            static let panelButtonRadius: CGFloat = 5
            /// Board 3: the Drop badge on the disk image.
            static let badgeFrame: CGFloat = 96
            static let badge: CGFloat = 32
            static let badgeBorder: CGFloat = 3
            static let badgeGlyph: CGFloat = 14
            static let badgeTrailing: CGFloat = 2
            static let badgeBottom: CGFloat = 6
            /// Board 4: two Login Items rows, Drop's switch on.
            static let listWidth: CGFloat = 260
            static let listVerticalPadding: CGFloat = 6
            static let listHorizontalPadding: CGFloat = 12
            static let listRowPadding: CGFloat = 8
            static let listRowSpacing: CGFloat = 10
            static let listIcon: CGFloat = 22
            static let listIconRadius: CGFloat = 6
            static let listIconGlyph: CGFloat = 11
            static let listLineWidth: CGFloat = 80
            static let listNameFont = SwiftUI.Font.system(size: 12, weight: .semibold)
            static let switchWidth: CGFloat = 26
            static let switchHeight: CGFloat = 15
            static let switchKnob: CGFloat = 11
            static let switchInset: CGFloat = 2
            /// Board 5: the green check.
            static let check: CGFloat = 72
            static let checkGlyph: CGFloat = 32
        }
    }

    enum MenuBar {
        static let statusDot: CGFloat = 8
    }

    /// Board colours mapped to system colours.
    enum Colour {
        static let good = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
        static let folder = Color(nsColor: .systemBlue)
        /// Small grey text: captions, info lines, subtitles. The system's secondary label
        /// measured about 3.1:1 on white at 11-12 pt and 4.0:1 on the dark panel (rendered
        /// pixels, `.claude/checks/contrast.sh`), under WCAG's 4.5:1, so it's the label colour
        /// at a lower opacity instead. Increase Contrast gets the full label colour.
        static let secondaryText = Color(nsColor: .readableSecondaryLabel)
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        static let bodyText = Color(nsColor: .labelColor)
        static let controlBackground = Color(nsColor: .controlBackgroundColor)
        static let textBackground = Color(nsColor: .textBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let accent = Color(nsColor: .controlAccentColor)
        static let link = Color(nsColor: .linkColor)
        static let onAccent = Color.white
        static let placeholderTile = Color(nsColor: .quaternaryLabelColor)
    }

    /// Opacities of the readable secondary label, tuned on rendered text to clear 4.5:1.
    enum Contrast {
        static let lightSecondaryOpacity: CGFloat = 0.68
        static let darkSecondaryOpacity: CGFloat = 0.68
    }

    /// How long things linger. Named so the timings can be tuned in one place.
    enum Timing {
        /// Board 3: "Closes on its own in a few seconds."
        static let doneAutoClose: Duration = .seconds(6)
        /// The temporary menu bar icon stays this long after the last panel closes.
        static let iconLinger: Duration = .seconds(3)
        /// A new `.dmg` must keep the same size this long before Drop reads it.
        static let stableSize: Duration = .milliseconds(1500)
        /// FSEvents coalescing latency, in seconds.
        static let eventLatency: CFTimeInterval = 0.5
        /// How long Quit and Update waits for the running app to quit by itself.
        static let quitTimeout: Duration = .seconds(30)
        /// While the pointer rests on board 3, how often it looks whether it has left.
        static let hoverRecheck: Duration = .milliseconds(500)
    }
}

extension NSColor {
    /// See `Theme.Colour.secondaryText`.
    static let readableSecondaryLabel = NSColor(name: "readableSecondaryLabel") { appearance in
        switch appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]) {
        case .darkAqua: NSColor(white: 1, alpha: Theme.Contrast.darkSecondaryOpacity)
        case .aqua: NSColor(white: 0, alpha: Theme.Contrast.lightSecondaryOpacity)
        default: .labelColor
        }
    }
}
