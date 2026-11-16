import AppKit
import Testing

@testable import DropApp

/// The Dock icon and Command-Tab follow the windows the user works in; the popup never
/// counts (it never calls the tracker).
struct ActivationPolicyTests {
    @Test func startsAsAnAccessory() {
        #expect(ActivationPolicyTracker().policy == .accessory)
    }

    @Test(arguments: ActivationPolicyTracker.Window.allCases)
    func anyWorkWindowMakesDropRegular(window: ActivationPolicyTracker.Window) {
        var tracker = ActivationPolicyTracker()
        #expect(tracker.opened(window) == .regular)
        #expect(tracker.closed(window) == .accessory)
    }

    @Test func staysRegularUntilTheLastWindowCloses() {
        var tracker = ActivationPolicyTracker()
        #expect(tracker.opened(.settings) == .regular)
        #expect(tracker.opened(.install) == nil, "already regular: nothing to apply")
        #expect(tracker.closed(.settings) == nil)
        #expect(tracker.policy == .regular)
        #expect(tracker.closed(.install) == .accessory)
    }

    @Test func reopeningOrClosingTwiceChangesNothing() {
        var tracker = ActivationPolicyTracker()
        _ = tracker.opened(.onboarding)
        #expect(tracker.opened(.onboarding) == nil)
        #expect(tracker.closed(.onboarding) == .accessory)
        #expect(tracker.closed(.onboarding) == nil)
        #expect(tracker.closed(.install) == nil, "the popup path closes .install even when it was never open")
    }
}
