import AppKit

/// What Drop does with the app and its own surface once an install has landed.
enum AfterInstallPlan: Equatable, Sendable {
    /// Installed stays up with Open and Show in Finder (the popup closes by itself later).
    case stay
    /// Quit and Update with "Open the app when it's installed" off: the app was running,
    /// so it reopens at once, and Installed stays up as for `stay`.
    case openInPlace
    /// "Open the app when it's installed" is on: Installed shows briefly, the surface
    /// closes, then the app opens. An update whose app was running takes this path too.
    case closeThenOpen

    /// - Parameters:
    ///   - openAfterInstall: the setting "Open the app when it's installed".
    ///   - wasRunning: Quit and Update quit the installed copy before the swap.
    init(openAfterInstall: Bool, wasRunning: Bool) {
        self = openAfterInstall ? .closeThenOpen : wasRunning ? .openInPlace : .stay
    }
}

/// Runs an `AfterInstallPlan` against a surface and an opener, both injected: the
/// controller passes the real window and `NSWorkspace`, the demo and the tests pass fakes.
///
/// For `closeThenOpen` the order is hold, hide, open: the surface is gone before the app
/// launches, so the app's own launch follows the exit with no overlap. The surface is only
/// hidden, not torn down, until the open succeeds; when it fails the caller still has
/// Installed and its buttons to bring back.
@MainActor
struct AfterInstall {
    enum Outcome: Equatable, Sendable {
        /// Installed is on screen with its buttons: the plan kept it, or the app didn't
        /// open and the surface came back.
        case showsInstalled
        /// The surface is hidden and the app is open: the caller finishes the panel.
        case closed
        /// The user acted on the panel first (Open, Show in Finder, Esc), or another panel
        /// took its place: nothing more was done, and the app was not opened.
        case superseded
    }

    /// Waits `Theme.Motion.installedHold`.
    var hold: () async -> Void
    /// Plays the surface's exit and hides it. False when the surface no longer shows this
    /// install, in which case it is left alone.
    var hideSurface: () async -> Bool
    /// Brings back the surface `hideSurface` hid, still on Installed.
    var restoreSurface: () -> Void
    /// Opens the installed app. False when it couldn't be opened.
    var open: (URL) async -> Bool

    func run(_ plan: AfterInstallPlan, app: URL) async -> Outcome {
        switch plan {
        case .stay:
            return .showsInstalled
        case .openInPlace:
            // Not awaited: the surface stays whatever happens, and its auto-close must
            // not wait for the app to finish launching.
            let open = open
            Task { _ = await open(app) }
            return .showsInstalled
        case .closeThenOpen:
            await hold()
            guard await hideSurface() else { return .superseded }
            if await open(app) { return .closed }
            restoreSurface()
            return .showsInstalled
        }
    }

    /// Opens `app` through Launch Services and waits for the launch. In a background test
    /// the app opens without activating, so a test copy never takes the user's focus.
    static func openApplication(_ app: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !WindowPresence.isBackgroundTest
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return true
        } catch {
            Log.app.error("Couldn't open \(app.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }
}
