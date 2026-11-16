import AppKit

/// One copy of Drop at a time. A second start (Finder, Spotlight, `open -n`) asks the
/// running copy to show Settings and exits. Demo and panel test launches (`--watch`,
/// `--destination`, `--trash`) are exempt, so screenshots and scripted checks run beside a
/// copy that watches the real Downloads, and never poke it.
@MainActor
func runDrop() {
    let launch = LaunchOptions()
    let me = ProcessInfo.processInfo.processIdentifier
    if launch.demo == nil, !launch.usesTestFolders, let bundleID = Bundle.main.bundleIdentifier,
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: {
            $0.processIdentifier != me
        })
    {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

MainActor.assumeIsolated { runDrop() }
