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
/// - `--destination <folder>`: install here instead of Applications.
/// - `--trash <folder>`: move trashed disk images and replaced apps here instead of the
///   Trash, so a test never touches the real one.
/// - `--no-login-item`: leave the login item alone (implied by any of the above).
/// - Debug builds only: `--demo <state>` shows one panel state with sample data, and
///   `--appearance light|dark` forces the appearance for screenshots.
struct LaunchOptions {
    var watchFolder: URL?
    var destination: URL?
    var trashFolder: URL?
    var manageLoginItem = true
    var demo: String?
    var appearance: String?
    /// Debug: ask Launch Services to make Drop the disk image default, print the result, quit.
    var probeHandler = false

    init(arguments: [String] = CommandLine.arguments) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--watch": watchFolder = iterator.next().map(Self.folder)
            case "--destination": destination = iterator.next().map(Self.folder)
            case "--trash": trashFolder = iterator.next().map(Self.folder)
            case "--no-login-item": manageLoginItem = false
            #if DEBUG
                case "--demo": demo = iterator.next()
                case "--appearance": appearance = iterator.next()
                case "--probe-handler": probeHandler = true
            #endif
            default: break
            }
        }
        if watchFolder != nil || destination != nil || trashFolder != nil || demo != nil || probeHandler {
            manageLoginItem = false
        }
    }

    var isTesting: Bool { !manageLoginItem }

    private static func folder(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory).standardizedFileURL
    }
}
