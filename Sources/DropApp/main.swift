import AppKit

/// One copy of Drop at a time. A second start (Finder, Spotlight, `open -n`) asks the
/// running copy to show Settings and exits. Demo and panel test launches (`--watch`,
/// `--destination`, `--trash`) are exempt, so screenshots and scripted checks run beside a
/// copy that watches the real Downloads, and never poke it.
///
/// Only a copy of this very app counts: the same bundle ID at the same bundle path. A
/// test build in `.build` shares the release bundle ID with an installed copy, and a copy
/// that started while a test copy ran must not take the test copy for itself and quit.
/// Debug builds also have their own bundle ID (`scripts/build-app.sh`).
@MainActor
func runDrop() {
    let launch = LaunchOptions()
    let me = ProcessInfo.processInfo.processIdentifier
    let myBundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    if launch.demo == nil, !launch.usesTestFolders, let bundleID = Bundle.main.bundleIdentifier,
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: {
            $0.processIdentifier != me
                && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == myBundle
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
