import Foundation

/// Whether a normal launch of Drop should hand over to a copy that's already running.
///
/// Release copies share one bundle ID wherever they live, so two installed copies
/// (`~/Applications` and `/Applications`) count as the same app: the older one wins and the
/// new launch exits. Otherwise both watch Downloads and stack a popup for every DMG.
///
/// Test builds are the exception. `scripts/build-app.sh` writes them inside `.build` with
/// the release bundle ID, so a running copy inside a `.build` directory never makes an
/// installed copy quit, and a launch from inside `.build` only defers to a copy at its
/// own path. Demo and test-folder launches (`exempt`) never defer. Debug builds have their
/// own bundle ID and never appear in `running` at all.
enum SingleInstance {
    /// Another running copy with the same bundle ID, as `NSRunningApplication` reports it.
    struct RunningCopy: Equatable, Sendable {
        let pid: pid_t
        /// Nil when the process has no bundle (it never counts).
        let bundleURL: URL?
    }

    /// True when this launch should ask the running copy to show Settings and exit.
    /// - Parameters:
    ///   - myPID: this process, which `running` may include.
    ///   - myBundle: this copy's bundle.
    ///   - exempt: a demo or test-folder launch, which always runs.
    ///   - running: every running app with this bundle ID.
    static func shouldDefer(
        myPID: pid_t, myBundle: URL, exempt: Bool, running: [RunningCopy]
    ) -> Bool {
        if exempt { return false }
        let mine = canonical(myBundle)
        let iAmTestBuild = isInsideBuildFolder(mine)
        return running.contains { copy in
            guard copy.pid != myPID, let url = copy.bundleURL else { return false }
            let theirs = canonical(url)
            if iAmTestBuild { return theirs == mine }
            return !isInsideBuildFolder(theirs)
        }
    }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Whether `url` lies inside a SwiftPM `.build` directory, where test builds live.
    static func isInsideBuildFolder(_ url: URL) -> Bool {
        url.pathComponents.contains(".build")
    }
}
