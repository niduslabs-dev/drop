import AppKit

/// One copy of Drop at a time. A second start (Finder, Spotlight, `open -n`) asks the
/// running copy to show Settings and exits; demo launches are exempt so screenshots can
/// run while Drop watches.
@MainActor
func runDrop() {
    let launch = LaunchOptions()
    let me = ProcessInfo.processInfo.processIdentifier
    if launch.demo == nil, let bundleID = Bundle.main.bundleIdentifier,
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
