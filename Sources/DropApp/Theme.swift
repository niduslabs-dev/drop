import AppKit
import SwiftUI

/// Sizes, spacing and colours from the approved design boards (`.claude/canvas/project`).
/// Colours are system colours so light and dark mode and the user's accent follow macOS;
/// only the layout numbers are fixed, and they live here rather than in the views.
enum Theme {
    /// The panel card (boards 1-3, Update, Warning, Fallback, Password, Licence).
    enum Panel {
        static let width: CGFloat = 400
        static let padding: CGFloat = 18
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

    enum MenuBar {
        static let statusDot: CGFloat = 8
    }

    /// Board colours mapped to system colours.
    enum Colour {
        static let good = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
        static let folder = Color(nsColor: .systemBlue)
        static let secondaryText = Color(nsColor: .secondaryLabelColor)
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
