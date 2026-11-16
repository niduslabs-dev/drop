import AppKit

/// Which of Drop's windows the user works in are open, and the activation policy that
/// follows: `.regular` (Dock icon, Command-Tab) while Settings, the install window or
/// onboarding is open, `.accessory` once the last one closes. The popup is never one of
/// them, so a download never puts Drop in the Dock. A value type with no AppKit state, so
/// tests drive it directly.
struct ActivationPolicyTracker: Equatable {
    enum Window: Hashable, CaseIterable {
        case settings
        case install
        case onboarding
    }

    private(set) var open: Set<Window> = []

    /// The policy for the windows open now.
    var policy: NSApplication.ActivationPolicy { open.isEmpty ? .accessory : .regular }

    /// Records `window` as open. Returns the new policy when it changed, else nil.
    mutating func opened(_ window: Window) -> NSApplication.ActivationPolicy? {
        let before = policy
        open.insert(window)
        return policy == before ? nil : policy
    }

    /// Records `window` as closed (closing one that wasn't open does nothing). Returns the
    /// new policy when it changed, else nil.
    mutating func closed(_ window: Window) -> NSApplication.ActivationPolicy? {
        let before = policy
        open.remove(window)
        return policy == before ? nil : policy
    }
}

/// Applies `ActivationPolicyTracker` to the running app. In a background test
/// (`--background-test`, and every demo) it keeps tracking but never changes the policy,
/// so a test copy never gets a Dock icon or a place in Command-Tab.
@MainActor
enum ActivationPolicy {
    typealias Window = ActivationPolicyTracker.Window

    private static var tracker = ActivationPolicyTracker()

    static func opened(_ window: Window) { apply(tracker.opened(window)) }
    static func closed(_ window: Window) { apply(tracker.closed(window)) }

    static var hasOpenWindow: Bool { !tracker.open.isEmpty }

    private static func apply(_ change: NSApplication.ActivationPolicy?) {
        guard let change, !WindowPresence.isBackgroundTest, NSApp.activationPolicy() != change else { return }
        NSApp.setActivationPolicy(change)
    }
}

/// How Drop's windows come forward. A window the user asked for (Settings, an opened disk
/// image, onboarding) activates Drop and takes focus like any app the user opens.
///
/// A background test (`--background-test`, and every `--demo`) must never take focus or
/// cover what the user is doing: windows are ordered in at the normal level behind every
/// other window, Drop is never activated, and nothing becomes key. `screencapture -l`
/// still captures them, occluded or not, and checks drive them through the accessibility
/// API.
@MainActor
enum WindowPresence {
    /// Set once at launch, before any window shows.
    static var isBackgroundTest = false

    /// Shows `window` as the one the user is working in.
    static func present(_ window: NSWindow) {
        if isBackgroundTest {
            orderInBehind(window)
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Shows a window that must not take focus (the popup): in front of other apps'
    /// windows normally, behind them in a background test.
    static func presentWithoutFocus(_ window: NSWindow) {
        if isBackgroundTest {
            orderInBehind(window)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Activates Drop for something that needs it (a save panel), except in a background test.
    static func activate() {
        guard !isBackgroundTest else { return }
        NSApp.activate()
    }

    /// The level `window` should float at: `level`, or `.normal` in a background test so it
    /// stays behind the user's windows.
    static func level(_ level: NSWindow.Level) -> NSWindow.Level { isBackgroundTest ? .normal : level }

    private static func orderInBehind(_ window: NSWindow) {
        window.level = .normal
        window.orderBack(nil)
    }
}
