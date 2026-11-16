import AppKit
import CoreText
import SwiftUI

/// Manrope, the Nidus Labs wordmark face, for onboarding headings and the byline only;
/// everything else uses the system font (Components board, Type row).
///
/// The variable font ships in the app bundle (`Contents/Resources/Fonts`, with its OFL
/// licence) and is registered for this process at launch. If registering fails, or the
/// face can't be built, `font(size:weight:)` returns the system font, so onboarding still
/// reads; the failure is logged.
@MainActor
enum Typeface {
    static let manropeFamily = "Manrope"
    private static let fileName = "Manrope-Variable"
    private static let fileExtension = "ttf"
    private static let folder = "Fonts"
    /// The OpenType `wght` axis tag, as Core Text names variation axes.
    private static let weightAxis: UInt32 = 0x7767_6874

    private(set) static var isManropeAvailable = false

    /// Registers the bundled Manrope. Call once at launch.
    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension, subdirectory: folder)
        else {
            Log.app.error("Manrope isn't in the bundle; onboarding uses the system font")
            return
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            isManropeAvailable = true
        } else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
            // Already registered (a second call) still leaves the face usable.
            isManropeAvailable = NSFontManager.shared.availableFontFamilies.contains(manropeFamily)
            Log.app.error("Couldn't register Manrope: \(reason, privacy: .public)")
        }
    }

    /// Manrope at `size` and `weight`, or the system font when Manrope isn't available.
    static func font(size: CGFloat, weight: NSFont.Weight) -> Font {
        guard isManropeAvailable, let font = manrope(size: size, weight: weight) else {
            return .system(size: size, weight: Font.Weight(weight))
        }
        return Font(font as CTFont)
    }

    private static func manrope(size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: manropeFamily,
            .variation: [NSNumber(value: weightAxis): NSNumber(value: Double(cssWeight(weight)))],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == manropeFamily else {
            return nil
        }
        return font
    }

    /// The CSS weight number for an AppKit weight, which is what the `wght` axis takes.
    private static func cssWeight(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight, .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy, .black: 800
        default: 400
        }
    }
}

extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}
