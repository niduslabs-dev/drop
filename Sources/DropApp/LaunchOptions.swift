import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "dev.niduslabs.drop", category: "app")
    static let watcher = Logger(subsystem: "dev.niduslabs.drop", category: "watcher")
}

/// Command-line switches for testing. Nothing here is needed in normal use, and none of
/// them changes saved settings.
///
/// - `--watch <folder>`: watch this folder instead of the one in Settings.
/// - `--destination <folder>`: install here instead of Applications (either choice).
/// - `--home-destination <folder>`: with "Applications in your home folder" chosen in the
///   panel, install here instead (else `--destination`, else `~/Applications`), so a test
///   can switch between two scratch folders.
/// - `--trash <folder>`: move trashed disk images and replaced apps here instead of the
///   Trash, so a test never touches the real one.
/// - `--no-login-item`: leave the login item alone (implied by any of the above).
/// - `--background-test`: a test copy that never takes focus or changes the Dock: no
///   activation, no key window, no activation policy change; windows order in behind the
///   user's (`WindowPresence`). Implies `--no-login-item`. Every `--demo` is one too.
/// - Debug builds only: `--demo <state>` shows one panel state with sample data (or an
///   onboarding page, `onboarding-1` to `onboarding-5`, `onboarding-2-denied`),
///   `--appearance light|dark` forces the appearance for screenshots, and
///   `--reset-onboarding` clears the test domain's onboarding state and shows onboarding.
///
/// Panel test launches (`--watch`, `--destination`, `--trash`) skip onboarding, so scripted
/// install checks see the panel straight away; add `--reset-onboarding` to run it there.
struct LaunchOptions {
    var watchFolder: URL?
    var destination: URL?
    var homeDestination: URL?
    var trashFolder: URL?
    var manageLoginItem = true
    var demo: String?
    var appearance: String?
    /// Debug: ask Launch Services to make Drop the disk image default, print the result, quit.
    var probeHandler = false
    /// Debug: forget onboarding in the test domain, then show it.
    var resetOnboarding = false
    /// `--background-test`.
    var backgroundTest = false

    init(arguments: [String] = CommandLine.arguments) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--watch": watchFolder = iterator.next().map(Self.folder)
            case "--destination": destination = iterator.next().map(Self.folder)
            case "--home-destination": homeDestination = iterator.next().map(Self.folder)
            case "--trash": trashFolder = iterator.next().map(Self.folder)
            case "--no-login-item": manageLoginItem = false
            case "--background-test": backgroundTest = true
            #if DEBUG
                case "--demo": demo = iterator.next()
                case "--appearance": appearance = iterator.next()
                case "--probe-handler": probeHandler = true
                case "--reset-onboarding": resetOnboarding = true
            #endif
            default: break
            }
        }
        if usesTestFolders || demo != nil || probeHandler || resetOnboarding || backgroundTest {
            manageLoginItem = false
        }
    }

    var isTesting: Bool { !manageLoginItem }

    /// Never take focus or change the activation policy (`--background-test`, any demo).
    var isBackgroundTest: Bool { backgroundTest || demo != nil }

    /// A panel test launch: any of `--watch`, `--destination`, `--home-destination` or `--trash`.
    var usesTestFolders: Bool {
        watchFolder != nil || destination != nil || homeDestination != nil || trashFolder != nil
    }

    /// Panel test launches go straight to the panel (see the type's notes).
    var skipsOnboarding: Bool { usesTestFolders && !resetOnboarding }

    private static func folder(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory).standardizedFileURL
    }
}
