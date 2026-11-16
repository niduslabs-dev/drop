import Foundation
import Installer

/// A disk image that holds Drop itself (SelfInstall board). Drop never offers Install or Quit
/// and Update for it: quitting itself would leave nothing to finish the swap. A newer version
/// points to Check for Updates, which installs the same signed release through Sparkle; the
/// same or an older one has nothing to install. A pure value, tested in `SelfImageTests`.
struct SelfImage: Equatable {
    enum Kind: Equatable {
        /// The image's Drop is newer than the running one: Check for Updates.
        case newer
        /// The same version or an older one: Done.
        case notNewer
    }

    /// The running copy's identity and versions, from its `Info.plist`.
    struct Running: Equatable {
        var bundleIdentifier: String?
        /// `CFBundleShortVersionString`.
        var version: String
        /// `CFBundleVersion`.
        var build: String?

        static var current: Running {
            let info = Bundle.main.infoDictionary ?? [:]
            return Running(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                version: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String)
        }
    }

    /// The release and debug builds' bundle IDs. Either one in an image counts as Drop for
    /// both builds, so a debug copy never offers to install a release Drop and the reverse.
    static let releaseIdentifier = "dev.niduslabs.drop"
    static let debugIdentifier = "dev.niduslabs.drop.debug"

    let kind: Kind
    /// The image's version, as people know it; nil when its `Info.plist` has none.
    let imageVersion: String?
    let currentVersion: String

    /// The board for `summary`, or nil when the image's app isn't Drop.
    static func offer(for summary: AppSummary, running: Running) -> SelfImage? {
        guard let identifier = summary.bundleIdentifier, isDrop(identifier, running: running.bundleIdentifier) else {
            return nil
        }
        let newer = isNewer(
            version: summary.version, build: summary.buildVersion, than: running.version, build: running.build)
        return SelfImage(
            kind: newer ? .newer : .notNewer, imageVersion: summary.version, currentVersion: running.version)
    }

    static func isDrop(_ identifier: String, running: String?) -> Bool {
        identifier == running || identifier == releaseIdentifier || identifier == debugIdentifier
    }

    /// Compares the short versions numerically ("1.0.10" after "1.0.9"), then the builds.
    /// An image without a version is never newer.
    static func isNewer(version: String?, build: String?, than current: String, build currentBuild: String?) -> Bool {
        guard let version else { return false }
        switch compare(version, current) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame:
            guard let build, let currentBuild else { return false }
            return compare(build, currentBuild) == .orderedDescending
        }
    }

    /// Dot-separated components compared as numbers; a missing component counts as 0, and
    /// a component's leading digits are its number ("2b3" is 2).
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    // MARK: Copy and buttons

    var title: String { imageVersion.map { "Drop \($0)" } ?? "Drop" }
    var subtitle: String { "You have \(currentVersion)" }

    var message: String {
        switch kind {
        case .newer: "Drop updates itself. Check for Updates installs this version and restarts Drop."
        case .notNewer: "This is your copy of Drop or an older one. There's nothing to install."
        }
    }

    struct Button: Equatable {
        var title: String
        var action: PanelAction
    }

    var primary: Button {
        switch kind {
        case .newer: Button(title: "Check for Updates", action: .checkForUpdates)
        case .notNewer: Button(title: "Done", action: .close)
        }
    }

    /// Not now for a newer Drop; nothing when there's nothing to decide.
    var secondary: Button? {
        kind == .newer ? Button(title: "Not now", action: .notNow) : nil
    }
}

/// Drop's own update check, as Settings' Check for Updates runs it. Injected into
/// `InstallController` so tests count the calls; debug and test launches have no updater,
/// so there it only logs.
@MainActor
struct UpdateCheck {
    var isAvailable: () -> Bool
    var start: () -> Void

    /// Starts a user-initiated check. False, and logged, when no updater runs.
    @discardableResult func run() -> Bool {
        guard isAvailable() else {
            Log.updates.info("Check for Updates from Drop's own disk image: no updater in this build")
            return false
        }
        start()
        return true
    }

    static func live(_ updates: UpdateModel) -> UpdateCheck {
        UpdateCheck(isAvailable: { updates.isEnabled }, start: { updates.perform(.check) })
    }
}
