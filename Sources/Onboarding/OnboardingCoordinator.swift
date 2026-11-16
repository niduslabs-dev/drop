import Foundation
import Observation
import os

/// The five onboarding pages, in order (boards Onboarding1 to Onboarding5).
public enum OnboardingPage: Int, CaseIterable, Codable, Sendable, Comparable {
    case welcome = 1
    case downloads
    case diskImages
    case loginItem
    case done

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
    public var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }
}

/// What the user allowed for the watched folder.
public enum FolderAccess: String, Codable, Sendable {
    /// Allow Downloads hasn't been clicked yet: Drop hasn't touched the folder.
    case notAsked
    /// Drop could list the folder (the user allowed macOS's Downloads prompt, or it was
    /// allowed before).
    case granted
    /// Listing failed with `EPERM`: the user said no in macOS's prompt or in System Settings.
    case denied
    /// The user chose another folder in the open panel, which grants access by itself.
    case otherFolder

    /// Drop may watch the folder now without making macOS ask.
    public var allowsWatching: Bool { self == .granted || self == .otherFolder }
}

/// The answer on "Open disk images with Drop?".
public enum DefaultHandlerChoice: String, Codable, Sendable {
    case notAsked
    /// Use Drop, and macOS's confirmation was accepted: Drop is now the default.
    case madeDefault
    /// Use Drop, but Drop isn't the default afterwards (the user cancelled macOS's dialog).
    case declined
    /// Not now.
    case skipped
}

/// The answer on "Start Drop when you log in?".
public enum LoginItemChoice: String, Codable, Sendable {
    case notAsked
    case registered
    /// Start at Login, but `SMAppService` refused (logged, not shown).
    case failed
    /// Not now.
    case skipped
}

/// How onboarding last ended.
public enum OnboardingOutcome: String, Codable, Sendable {
    /// Never shown, or open right now.
    case inProgress
    /// Done on the last page (or closed there, which means the same).
    case completed
    /// Closed early with Esc or the close button.
    case dismissed
}

/// Why onboarding will show again at the next launch.
public enum ReshowReason: String, Codable, Sendable {
    /// Closed early before Drop had access to the watched folder. Drop can't do its main job
    /// without it, and it never asks macOS by itself, so onboarding is the only way back.
    case folderAccessNotGranted
}

/// Everything onboarding remembers, saved as one JSON value in the app's preferences.
public struct OnboardingState: Codable, Equatable, Sendable {
    /// The furthest page the user saw.
    public var reached: OnboardingPage = .welcome
    public var folderAccess: FolderAccess = .notAsked
    public var defaultHandler: DefaultHandlerChoice = .notAsked
    public var loginItem: LoginItemChoice = .notAsked
    public var outcome: OnboardingOutcome = .inProgress
    public var reshowReason: ReshowReason?

    public init() {}
}

/// The result of Drop's first listing of the watched folder.
public enum FolderAccessResult: Equatable, Sendable {
    case granted
    /// `EPERM` or `EACCES`: macOS's privacy control said no.
    case denied
    /// Any other error (the folder is gone, say), with its `errno`. Treated like denied.
    case failed(Int32)
}

/// Lists the watched folder, which is what makes macOS show its "access files in your
/// Downloads folder" prompt the first time. Fakes in tests.
public protocol FolderAccessChecking: Sendable {
    func requestAccess(to folder: URL) async -> FolderAccessResult
}

/// Makes Drop the default for disk images (macOS asks the user to confirm) and returns
/// whether it is afterwards.
@MainActor
public protocol DefaultHandlerSetting {
    func makeDropDefault() async -> Bool
}

/// Registers Drop's login item (`SMAppService.mainApp`).
@MainActor
public protocol LoginItemRegistering {
    func register() throws
}

/// First-launch onboarding's state machine. Drop touches nothing the user hasn't agreed
/// to: the watched folder, the default handler and the login item are each requested only
/// by their page's button, and the app asks `allowsWatching` before it starts the watcher.
///
/// The rules, persisted in the given defaults (the test domain in test launches):
/// - Shown at launch until it's completed, or until it's closed early after Drop got access
///   to the watched folder (`showsAtLaunch`). Closing early without access records
///   `ReshowReason.folderAccessNotGranted` and onboarding returns next launch, at the
///   Downloads page when the user got that far.
/// - The watcher may start once access was granted or another folder chosen, or once
///   onboarding is completed (after Continue anyway macOS won't ask again, so starting it
///   can't surprise anyone).
/// - Not now on the login page leaves "Open Drop at login" off; nothing else turns it on.
@MainActor
@Observable
public final class OnboardingCoordinator {
    public static let defaultsKey = "onboarding"

    public private(set) var state: OnboardingState
    /// The page on screen. Starts where the user left off (see `showsAtLaunch`).
    public private(set) var page: OnboardingPage
    /// A button's request is running (macOS's prompt is up); the buttons wait.
    public private(set) var isBusy = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folderAccess: any FolderAccessChecking
    @ObservationIgnored private let defaultHandler: any DefaultHandlerSetting
    @ObservationIgnored private let loginItem: any LoginItemRegistering
    @ObservationIgnored private let log = Logger(subsystem: "dev.niduslabs.drop", category: "onboarding")

    /// Drop may now watch the folder: start the watcher.
    @ObservationIgnored public var onWatchingAllowed: () -> Void = {}
    /// The user chose another folder to watch; store it before `onWatchingAllowed` runs.
    @ObservationIgnored public var onFolderChosen: (URL) -> Void = { _ in }
    /// Use Drop finished; the argument is whether Drop is the default now.
    @ObservationIgnored public var onDefaultHandlerChanged: (Bool) -> Void = { _ in }
    /// The user answered the login page; true for Start at Login, false for Not now.
    @ObservationIgnored public var onLoginItemChosen: (Bool) -> Void = { _ in }
    /// Onboarding ended (Done or closed early): close the window.
    @ObservationIgnored public var onEnd: () -> Void = {}

    public init(
        defaults: UserDefaults, folderAccess: any FolderAccessChecking, defaultHandler: any DefaultHandlerSetting,
        loginItem: any LoginItemRegistering
    ) {
        self.defaults = defaults
        self.folderAccess = folderAccess
        self.defaultHandler = defaultHandler
        self.loginItem = loginItem
        let saved =
            defaults.data(forKey: Self.defaultsKey).flatMap {
                try? JSONDecoder().decode(OnboardingState.self, from: $0)
            }
            ?? OnboardingState()
        state = saved
        page = saved.reached >= .downloads && !saved.folderAccess.allowsWatching ? .downloads : .welcome
    }

    /// Removes the saved state, so the next coordinator starts from scratch.
    public static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    public var isComplete: Bool { state.outcome == .completed }

    /// Whether the app should open onboarding at launch.
    public var showsAtLaunch: Bool {
        switch state.outcome {
        case .completed: false
        case .dismissed: state.reshowReason != nil
        case .inProgress: true
        }
    }

    /// Whether the app may start the watcher (its first touch of the folder).
    public var allowsWatching: Bool { isComplete || state.folderAccess.allowsWatching }

    /// The Downloads page shows the denied line and Continue anyway.
    public var showsFolderDenied: Bool {
        state.folderAccess == .denied && page == .downloads
    }

    // MARK: Buttons

    /// Get Started.
    public func getStarted() { show(.downloads) }

    /// Allow Downloads: lists the folder, which makes macOS ask the first time.
    public func allowFolder(_ folder: URL) async {
        guard !isBusy else { return }
        isBusy = true
        let result = await folderAccess.requestAccess(to: folder)
        isBusy = false
        switch result {
        case .granted:
            update { $0.folderAccess = .granted }
            onWatchingAllowed()
            show(.diskImages)
        case .denied:
            log.info("Folder access denied")
            update { $0.folderAccess = .denied }
        case .failed(let code):
            log.error("Couldn't list the watched folder: errno \(code)")
            update { $0.folderAccess = .denied }
        }
    }

    /// Choose another folder, after the open panel returned one.
    public func useFolder(_ folder: URL) {
        update { $0.folderAccess = .otherFolder }
        onFolderChosen(folder)
        onWatchingAllowed()
        show(.diskImages)
    }

    /// Continue anyway, after access was denied.
    public func continueWithoutFolder() { show(.diskImages) }

    /// Use Drop: the next page follows whatever the user answered in macOS's dialog.
    public func useDrop() async {
        guard !isBusy else { return }
        isBusy = true
        let isDefault = await defaultHandler.makeDropDefault()
        isBusy = false
        update { $0.defaultHandler = isDefault ? .madeDefault : .declined }
        onDefaultHandlerChanged(isDefault)
        show(.loginItem)
    }

    /// Not now on the disk images page.
    public func skipDefaultHandler() {
        update { $0.defaultHandler = .skipped }
        show(.loginItem)
    }

    /// Start at Login. A failure is logged and onboarding moves on: Drop works while it
    /// runs either way, and Settings can try again.
    public func startAtLogin() {
        do {
            try loginItem.register()
            update { $0.loginItem = .registered }
        } catch {
            log.error("Login item register failed: \(error, privacy: .public)")
            update { $0.loginItem = .failed }
        }
        onLoginItemChosen(true)
        show(.done)
    }

    /// Not now on the login page.
    public func skipLoginItem() {
        update { $0.loginItem = .skipped }
        onLoginItemChosen(false)
        show(.done)
    }

    /// Done.
    public func finish() {
        update {
            $0.outcome = .completed
            $0.reshowReason = nil
        }
        onEnd()
    }

    /// Left arrow: back a page. Requests already made stay made.
    public func goBack() {
        guard !isBusy, let previous = page.previous else { return }
        page = previous
    }

    /// The window was closed (Esc or the close button). On the last page that's Done.
    public func windowClosed() {
        guard !isComplete else { return }
        guard page != .done else {
            finish()
            return
        }
        update {
            $0.outcome = .dismissed
            $0.reshowReason = $0.folderAccess.allowsWatching ? nil : .folderAccessNotGranted
        }
        onEnd()
    }

    /// Showing onboarding again at launch starts it over as in progress.
    public func reopened() {
        guard state.outcome == .dismissed else { return }
        update { $0.outcome = .inProgress }
    }

    #if DEBUG
        /// Screenshots (`--demo onboarding-<n>`): shows a page without its requests.
        public func preview(_ page: OnboardingPage) { self.page = page }
    #endif

    // MARK: State

    private func show(_ next: OnboardingPage) {
        page = next
        if next > state.reached { update { $0.reached = next } }
    }

    private func update(_ change: (inout OnboardingState) -> Void) {
        change(&state)
        do {
            defaults.set(try JSONEncoder().encode(state), forKey: Self.defaultsKey)
        } catch {
            log.error("Couldn't save onboarding: \(error, privacy: .public)")
        }
    }
}
