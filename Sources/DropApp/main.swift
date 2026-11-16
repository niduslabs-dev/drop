import AppKit

/// One copy of Drop at a time. A second start (Finder, Spotlight, `open -n`) asks the
/// running copy to show Settings and exits, even when the two copies sit at different
/// paths (`~/Applications` and `/Applications`), so only one watches Downloads. Demo and
/// panel test launches (`--watch`, `--destination`, `--trash`) are exempt, so screenshots
/// and scripted checks run beside a copy that watches the real Downloads, and never poke it.
///
/// Test builds in `.build` share the release bundle ID, so they are kept apart: a running
/// `.build` copy never makes an installed copy quit, and a `.build` launch only defers to a
/// copy at its own path. The rule is `SingleInstance.shouldDefer`. Debug builds also have
/// their own bundle ID (`scripts/build-app.sh`).
@MainActor
func runDrop() {
    let launch = LaunchOptions()
    if let bundleID = Bundle.main.bundleIdentifier,
        SingleInstance.shouldDefer(
            myPID: ProcessInfo.processInfo.processIdentifier,
            myBundle: Bundle.main.bundleURL,
            exempt: launch.demo != nil || launch.usesTestFolders,
            running: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map {
                SingleInstance.RunningCopy(pid: $0.processIdentifier, bundleURL: $0.bundleURL)
            })
    {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // A background test leaves the policy as Info.plist sets it (LSUIElement: accessory).
    WindowPresence.isBackgroundTest = launch.isBackgroundTest
    if !launch.isBackgroundTest { app.setActivationPolicy(.accessory) }
    withExtendedLifetime(delegate) { app.run() }
}

MainActor.assumeIsolated { runDrop() }
