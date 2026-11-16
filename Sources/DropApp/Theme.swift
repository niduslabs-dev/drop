import AppKit
import SwiftUI

/// Sizes, spacing, colours and motion from the approved design boards
/// (`.claude/canvas/project`) and the Nidus component kit (`Components.dc.html`). Views read
/// every number from here; none adds its own.
enum Theme {
    /// The install panel's content inset, the same on all four sides (every panel board).
    /// The centred window keeps it on the left, right and bottom; its top is the title bar.
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
        /// The boards' card is the surface at 92% over the popover material.
        static let surfaceOpacity: Double = 0.92
        static let titleSpacing: CGFloat = 2
        static let updateTitleSpacing: CGFloat = 4
        static let buttonRowTopPadding: CGFloat = 2
    }

    /// Dark mode's "ink glass" (DarkMode board, option 3): a dark behind-window material with
    /// an ink tint over it. Reduce Transparency gets solid ink instead. Light mode is the
    /// white surface (over the popover material for the popup).
    enum Glass {
        static let darkMaterial = NSVisualEffectView.Material.hudWindow
        static let lightPopupMaterial = NSVisualEffectView.Material.popover
        /// The popup and the centred window, and onboarding.
        static let panelTint = Color(nsColor: NSColor(hex: 0x1C1B22))
        static let panelTintOpacity: Double = 0.86
        /// Settings' window behind its groups.
        static let settingsTint = Color(nsColor: NSColor(hex: 0x18171D))
        static let settingsTintOpacity: Double = 0.88
        /// Reduce Transparency: solid ink.
        static let solidPanel = Color(nsColor: NSColor(hex: 0x232229))
        static let solidWindow = Color(nsColor: NSColor(hex: 0x1C1B21))
    }

    /// Where the popup sits: the Arrival board's top right, this far inside the visible
    /// frame (below the menu bar, left of the Dock if it's on the right).
    enum Popup {
        static let screenInset: CGFloat = 12
    }

    /// The centred window an opened disk image gets (Arrival board, right).
    enum CentredWindow {
        /// Space between the title bar (read from the window) and the first line.
        static let titleGap: CGFloat = 4
    }

    enum Icon {
        static let size: CGFloat = 60
        static let cornerRadius: CGFloat = 14
        static let licenceSize: CGFloat = 48
        static let licenceCornerRadius: CGFloat = 12
        static let glyph: CGFloat = 30
        static let placeholderGlyphScale: CGFloat = 0.9
        static let placeholderFillOpacity: Double = 0.5
        static let licenceGlyph: CGFloat = 26
        static let titleSpacing: CGFloat = 14
        /// The green check on board 3's icon.
        static let badge: CGFloat = 24
        static let badgeBorder: CGFloat = 2
        static let badgeOffset: CGFloat = 6
        static let badgeStroke: CGFloat = 2.2
        /// Settings' Recent list.
        static let recentSize: CGFloat = 22
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let licenceTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let subtitle = SwiftUI.Font.system(size: 12)
        static let body = SwiftUI.Font.system(size: 13)
        static let small = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let captionStrong = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let calloutTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let button = SwiftUI.Font.system(size: 13, weight: .medium)
        static let primaryButton = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let link = SwiftUI.Font.system(size: 12)
        /// Title tracking: -0.01em of 17 pt.
        static let titleTracking: CGFloat = -0.17
    }

    /// The kit's info cards: neutral (ok), warn and error.
    enum Card {
        static let verticalPadding: CGFloat = 11
        static let horizontalPadding: CGFloat = 12
        static let cornerRadius: CGFloat = 10
        static let rowSpacing: CGFloat = 7
        static let iconSpacing: CGFloat = 8
        static let calloutSpacing: CGFloat = 10
        static let calloutLineSpacing: CGFloat = 4
        static let rowIcon: CGFloat = 14
        static let rowGlyph: CGFloat = 12
        static let calloutIcon: CGFloat = 16
        static let calloutGlyph: CGFloat = 13
        static let lineSpacing: CGFloat = 2.5
        /// The neutral fill's ink share, for drawings that mix it into a solid colour.
        static let fillOpacity: Double = 0.04
        static let darkFillOpacity: Double = 0.06
    }

    /// The kit's buttons: capsules for actions, radius 8 for value controls (select, field).
    enum Button {
        static let height: CGFloat = 30
        static let padding: CGFloat = 16
        /// Settings' Change… and Quit Drop.
        static let smallHeight: CGFloat = 28
        static let smallPadding: CGFloat = 14
        static let spacing: CGFloat = 8
        static let linkPadding: CGFloat = 2
        static let linkFocusRadius: CGFloat = 4
        /// Secondary hover and press: ink over the paper, as on the board.
        static let hoverShade: Double = 0.04
        static let pressShade: Double = 0.08
        static let hairline: CGFloat = 1
    }

    /// The kit's value controls.
    enum Control {
        static let cornerRadius: CGFloat = 8
        static let focusRing: CGFloat = 3
        static let disabledOpacity: Double = 0.45
        static let selectLeading: CGFloat = 12
        static let selectTrailing: CGFloat = 10
        static let selectSpacing: CGFloat = 8
        static let selectIcon: CGFloat = 13
        static let selectChevron: CGFloat = 9
        /// Space between the select and the menu it opens.
        static let menuGap: CGFloat = 4
        static let switchWidth: CGFloat = 34
        static let switchHeight: CGFloat = 20
        static let switchKnob: CGFloat = 16
        static let switchInset: CGFloat = 2
        static let switchBorder: CGFloat = 1
        static let knobShadowOpacity: Double = 0.25
        static let knobShadowRadius: CGFloat = 1
        static let knobShadowY: CGFloat = 1
        static let switchLabelSpacing: CGFloat = 12
        static let captionSpacing: CGFloat = 2
        static let fieldVerticalPadding: CGFloat = 7
        static let fieldHorizontalPadding: CGFloat = 11
        static let fieldBorder: CGFloat = 1
    }

    enum Header {
        static let spacing: CGFloat = 6
        static let icon: CGFloat = 11
        static let glyph: CGFloat = 12
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
        /// `#D1D1D6` dots and placeholder bars: ink at this opacity in both modes.
        static let mutedOpacity: Double = 0.18
        /// `#E5E5EA` tiles, the off switch and the screen in the page 2 drawing.
        static let faintOpacity: Double = 0.1
        static let hairlineOpacity: Double = 0.08
        static let rowDividerOpacity: Double = 0.06
        static let shadowOpacity: Double = 0.1
        static let shadowRadius: CGFloat = 9
        static let shadowY: CGFloat = 6

        /// Manrope 22 bold (Components board, Type row).
        static let titleSize: CGFloat = 22
        static let titleWeight: NSFont.Weight = .bold
        /// -0.01em of 22 pt.
        static let titleTracking: CGFloat = -0.22
        static let infoFont = SwiftUI.Font.system(size: 11)
        /// Board 5's byline: Manrope 12, secondary text colour.
        static let bylineSize: CGFloat = 12
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
            /// Board 2: a screen corner with the popup at its top right.
            static let screenWidth: CGFloat = 320
            static let screenHeight: CGFloat = 150
            static let screenRadius: CGFloat = 10
            static let screenBar: CGFloat = 14
            static let screenBarOpacity: Double = 0.8
            static let popupInset: CGFloat = 8
            static let popupTop: CGFloat = 22
            static let bar: CGFloat = 6
            static let thinBar: CGFloat = 5
            static let panelWidth: CGFloat = 190
            static let panelRadius: CGFloat = 10
            static let panelPadding: CGFloat = 10
            static let panelSpacing: CGFloat = 8
            static let panelTile: CGFloat = 28
            static let panelTileRadius: CGFloat = 7
            static let panelLineSpacing: CGFloat = 4
            static let panelTitleWidth: CGFloat = 60
            static let panelSubtitleWidth: CGFloat = 90
            static let panelButtonWidth: CGFloat = 36
            static let panelButtonHeight: CGFloat = 16
            /// The sample app's icon colour on the boards (Linea's blue).
            static let sampleAppTile = Color(nsColor: .nidus(light: 0x2F6FEB, dark: 0x2F6FEB))
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
            /// Board 5: the green check, drawn in.
            static let check: CGFloat = 72
            static let checkStroke: CGFloat = 5
            static let lineWidth: CGFloat = 1
        }
    }

    /// The kit's colours as dynamic colours: light, dark, and an Increase Contrast variant
    /// of each. Every text colour was measured on rendered pixels (`.claude/screens/app-v2/
    /// measurements.md`); the hex values are the Components board's.
    enum Colour {
        /// Moss: the accent in both modes. White on it is 4.98:1.
        static let accent = Color(nsColor: .nidus(light: 0x4F7A4A, dark: 0x4F7A4A, contrast: 0x3B5D38))
        static let accentHover = Color(
            nsColor: .nidus(light: 0x456B41, dark: 0x527F4C, contrast: 0x34522F, darkContrast: 0x3B5D38))
        static let accentPressed = Color(
            nsColor: .nidus(light: 0x3B5D38, dark: 0x456B41, contrast: 0x2C4529, darkContrast: 0x34522F))
        /// Links and accent icons: a shade under moss on light (#466E41; moss itself measured
        /// 4.48:1 on the info card and 4.2:1 on Settings' rows, under 4.5), light moss on dark.
        static let link = Color(
            nsColor: .nidus(light: 0x466E41, dark: 0x8DBB82, contrast: 0x3B5D38, darkContrast: 0xA9D19F))
        static let onAccent = Color.white
        /// Ink: body text.
        static let bodyText = Color(
            nsColor: .nidus(light: 0x17161C, dark: 0xF4F4F6, contrast: 0x000000, darkContrast: 0xFFFFFF))
        /// Captions, subtitles, info lines. A shade under the kit's #6B6A73, which measured
        /// 4.36:1 on Settings' grouped rows: 5.9:1 on white, 4.8:1 on those rows, 8:1 on dark.
        static let secondaryText = Color(
            nsColor: .nidus(light: 0x64636C, dark: 0xB9B8C2, contrast: 0x3E3D45, darkContrast: 0xDCDBE3))
        /// Decoration and pending-step glyphs only, never text: 3:1 against the surface.
        static let tertiaryText = Color(nsColor: .controlBoundary)
        /// The panel and window surface.
        static let surface = Color(nsColor: .nidus(light: 0xFFFFFF, dark: 0x232229))
        /// Secondary buttons, the select and fields.
        static let paper = Color(nsColor: .paper)
        /// The board's hairline: ink at 12% (paper at 14% on dark); the boundary colour under
        /// Increase Contrast.
        static let hairline = Color(nsColor: .hairline)
        /// Boundaries that carry a control's state (the off switch track, fields): 3:1.
        static let controlBoundary = Color(nsColor: .controlBoundary)
        static let focusRing = Color(nsColor: .focusRing)
        static let switchOff = Color(nsColor: .nidus(light: 0xD8D7DE, dark: 0x4A4952))
        /// The neutral info card's fill.
        static let infoFill = Color(nsColor: .infoFill)
        /// Green status icons (signed, notarized, done steps).
        static let good = Color(
            nsColor: .nidus(light: 0x2F7A3A, dark: 0x8DBB82, contrast: 0x225C2B, darkContrast: 0xA9D19F))
        /// The Installed check's fill, with white on it in both modes (5.3:1).
        static let success = Color(nsColor: .nidus(light: 0x2F7A3A, dark: 0x2F7A3A, contrast: 0x225C2B))
        static let warnFill = Color(nsColor: .warnFill)
        static let warnText = Color(
            nsColor: .nidus(light: 0x6B4300, dark: 0xF5D3A1, contrast: 0x4A2F00, darkContrast: 0xFFE7C4))
        static let warnTitle = Color(
            nsColor: .nidus(light: 0x4A2F00, dark: 0xF5D3A1, contrast: 0x2E1D00, darkContrast: 0xFFE7C4))
        /// The warn icon, and Install Anyway (4.67:1 on white).
        static let warning = Color(
            nsColor: .nidus(light: 0xB25E00, dark: 0xF0A44B, contrast: 0x8A4800, darkContrast: 0xFFC27A))
        static let errorFill = Color(nsColor: .errorFill)
        /// The error icon and error text (5.75:1 on white, 6.9:1 on the dark surface).
        static let error = Color(
            nsColor: .nidus(light: 0xC4271B, dark: 0xFF8A80, contrast: 0x9E1D13, darkContrast: 0xFFB0A8))
        static let placeholderTile = Color(nsColor: .quaternaryLabelColor)
        static let separator = Color(nsColor: .hairline)
        static let textBackground = Color(nsColor: .textBackgroundColor)
        static let folder = link
    }

    /// Motion values from Purge (`.claude/research/purge-design.md`), re-implemented. Every
    /// animation has a Reduce Motion path, written beside its use.
    enum Motion {
        /// Popup entrance: the window slides in by its width, the content sharpens and settles.
        static let popupResponse: Double = 0.4
        static let popupDamping: Double = 0.9
        static let popupBlur: CGFloat = 6
        static let popupOffset: CGFloat = 8
        static var popup: Animation { .spring(response: popupResponse, dampingFraction: popupDamping) }
        /// Reduce Motion: a fade, no slide or blur.
        static let fadeDuration: Double = 0.2
        static var fade: Animation { .easeOut(duration: fadeDuration) }
        /// How close to its target the window frame spring counts as settled, in points.
        static let settleEpsilon: Double = 0.001

        /// Status line swap: blur, drift and fade (Purge's blurFade).
        static let swapBlur: CGFloat = 6
        static let swapOffset: CGFloat = 5
        static var swap: Animation { .spring(response: 0.4, dampingFraction: 0.9) }

        /// Staging steps on board 2 appear one at a time.
        static let stepInterval: Duration = .milliseconds(550)
        static let stepRise: CGFloat = 8
        static var step: Animation { .easeOut(duration: 0.4) }
        /// The progress bar never passes this until the install is done.
        static let progressCeiling: Double = 0.9
        static var progress: Animation { .easeInOut(duration: 0.3) }
        /// Board 2 stays up at least this long, so a fast install doesn't flash past.
        static let installingHold: Duration = .milliseconds(900)

        /// The drawn Installed check.
        static var checkDraw: Animation { .easeInOut(duration: 0.6) }
        static let checkScaleFrom: CGFloat = 0.85
        static var checkScale: Animation { .spring(response: 0.35, dampingFraction: 0.7) }
        /// The beat between the badge scaling in and the stroke starting.
        static let checkBeat: Double = 0.15

        /// Numbers that change roll: progress, sizes.
        static var numbers: Animation { .easeInOut(duration: 0.45) }

        /// Onboarding: the old page blurs out, the new page's elements blur in in turn.
        static let pageBlur: CGFloat = 8
        static var page: Animation { .easeInOut(duration: 0.35) }
        static let staggerBlur: CGFloat = 10
        static let staggerDuration: Double = 0.45
        static let staggerStep: Double = 0.08

        /// Control states (Purge's button rules).
        static var hover: Animation { .easeOut(duration: 0.12) }
        static var enable: Animation { .easeInOut(duration: 0.28) }
        static var toggle: Animation { .spring(response: 0.25, dampingFraction: 0.85) }
    }

    /// How long things linger. Named so the timings can be tuned in one place.
    enum Timing {
        /// Board 3: "Closes on its own in a few seconds."
        static let doneAutoClose: Duration = .seconds(6)
        /// A `.dmg` that appears without a rename (a Finder copy, `curl -o`) must keep the
        /// same size this long before Drop reads it. A rename into the name is a finished
        /// download and skips the wait.
        static let stableSize: Duration = .milliseconds(400)
        /// FSEvents coalescing latency, in seconds.
        static let eventLatency: CFTimeInterval = 0.1
        /// How long Quit and Update waits for the running app to quit by itself.
        static let quitTimeout: Duration = .seconds(30)
        /// While the pointer rests on board 3, how often it looks whether it has left.
        static let hoverRecheck: Duration = .milliseconds(500)
    }
}

extension NSColor {
    /// A colour from the kit: `light` and `dark`, and their Increase Contrast variants
    /// (`contrast` for light, `darkContrast` for dark; each falls back to its mode's value).
    static func nidus(
        light: UInt32, dark: UInt32, contrast: UInt32? = nil, darkContrast: UInt32? = nil, alpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex: UInt32
            switch appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]) {
            case .darkAqua: hex = dark
            case .accessibilityHighContrastAqua: hex = contrast ?? light
            case .accessibilityHighContrastDarkAqua: hex = darkContrast ?? dark
            default: hex = light
            }
            return NSColor(hex: hex, alpha: alpha)
        }
    }

    /// One colour per appearance, for the translucent tokens.
    static func nidus(light: NSColor, dark: NSColor, contrast: NSColor, darkContrast: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: contrast
            case .accessibilityHighContrastDarkAqua: darkContrast
            default: light
            }
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let channel = { (shift: UInt32) in CGFloat((hex >> shift) & 0xFF) / 255 }
        self.init(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: alpha)
    }

    private static let ink: UInt32 = 0x17161C
    private static let paperHex: UInt32 = 0xF4F4F6

    static let controlBoundary = nidus(light: 0x8A8992, dark: 0x7A7983, contrast: 0x5E5D66, darkContrast: 0xA09FA8)
    /// Secondary buttons, the select and fields: paper on light, #2C2B33 at 90% on the dark
    /// glass (solid under Increase Contrast).
    static let paper = nidus(
        light: NSColor(hex: paperHex), dark: NSColor(hex: 0x2C2B33, alpha: 0.9), contrast: NSColor(hex: paperHex),
        darkContrast: NSColor(hex: 0x2C2B33))
    static let hairline = nidus(
        light: NSColor(hex: ink, alpha: 0.12), dark: NSColor(hex: paperHex, alpha: 0.12),
        contrast: .controlBoundary, darkContrast: .controlBoundary)
    static let focusRing = nidus(
        light: NSColor(hex: 0x4F7A4A, alpha: 0.35), dark: NSColor(hex: 0x8DBB82, alpha: 0.45),
        contrast: NSColor(hex: 0x3B5D38), darkContrast: NSColor(hex: 0xA9D19F))
    static let infoFill = nidus(
        light: NSColor(hex: ink, alpha: 0.04), dark: NSColor(hex: paperHex, alpha: 0.06),
        contrast: NSColor(hex: ink, alpha: 0.08), darkContrast: NSColor(hex: paperHex, alpha: 0.12))
    static let warnFill = nidus(
        light: NSColor(hex: 0xFFF4E0), dark: NSColor(hex: 0xFFAA3C, alpha: 0.14), contrast: NSColor(hex: 0xFFF4E0),
        darkContrast: NSColor(hex: 0xFFAA3C, alpha: 0.2))
    static let errorFill = nidus(
        light: NSColor(hex: 0xFDECEA), dark: NSColor(hex: 0xFF5A50, alpha: 0.14), contrast: NSColor(hex: 0xFDECEA),
        darkContrast: NSColor(hex: 0xFF5A50, alpha: 0.2))
}
