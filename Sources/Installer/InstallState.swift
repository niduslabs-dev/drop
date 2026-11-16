import DiskImage
import Extractor
import Foundation
import ReaderCore
import Verifier

/// What the panel shows for one DMG, in the order a session moves through it:
///
/// ```
/// reading ─▶ needsLicence ─▶ (needsPassword) ─▶ preparing ─▶ ready ───────────▶ installing ─▶ installed
///    │            │           ▲   │      ├▶ warning ──(install)─▶ installing
///    │            │           ▼   │      └▶ refused
///    │            │     waitingToPrepare ──(install)─▶ installing
///    ├▶ cannotInstall / failed (from reading or preparing)
///    └─ cancel() or decline() from any state before installed ─▶ cancelled
/// ```
///
/// `install()` during `preparing` moves straight to `installing` (staging finishes at full
/// speed, then the app moves into place), unless the verdict turns out to be a warning or a
/// refusal: then the session stops at `warning` or `refused` and waits, because Install
/// Anyway is a separate decision the user hasn't made yet.
///
/// `preparing` and `waitingToPrepare` swap as Low Power Mode or thermal pressure comes and
/// goes (`InstallOptions.conditions`); both show the same panel with Install enabled.
///
/// An image Drop can't read itself (`ReaderError.wantsMountFallback`: encrypted, sparse, an
/// unknown compression, decmpfs files) takes the hidden mount through the same states: the
/// licence (when the container's plist is readable), `needsPassword` for an encrypted image,
/// then `preparing` onwards from the mounted volume. The image is detached as soon as the
/// app is staged, and on cancel or any failure.
public enum InstallState: Sendable, Equatable {
    /// Opening the image and reading its catalog. Usually under 0.1 s.
    case reading
    /// The image carries a licence agreement. Nothing is staged until `acceptLicence()`;
    /// `decline()` ends the session. `preview` names the app and carries its icon when the
    /// image could be read directly; nil on the hidden-mount path, which reads the licence
    /// before anything is attached.
    case needsLicence(LicenceAgreement, preview: AppPreview?)
    /// Staging and checking the app in the background. The summary already has the name,
    /// version, bundle ID, size and installed version; the signer fields fill in at `ready`.
    case preparing(AppSummary, InstallProgress)
    /// Low Power Mode is on, or the Mac is hot (thermal state serious or worse): staging
    /// waits, between files if it had begun, and nothing runs until the state clears
    /// (back to `preparing`) or Install (to `installing`, at full speed). A separate state
    /// rather than a flag on `preparing`, so a panel that binds to progress can't show a
    /// bar that silently stops moving.
    case waitingToPrepare(AppSummary)
    /// Notarized and intact: Install is a rename.
    case ready(AppSummary)
    /// "Apple hasn't checked this app": `install()` here is Install Anyway.
    case warning(AppSummary, Verdict.Warning)
    /// Hard stop. The staged copy is already deleted and the installed copy was never touched.
    case refused(AppSummary, Verdict.Refusal)
    /// Not something Drop installs (a package, several apps, none), or an image that
    /// doesn't open at all. The panel offers "Open disk image" or Installer instead.
    case cannotInstall(CannotInstallReason)
    /// The image is encrypted: `providePassword(_:)` attaches it (hidden), `cancel()` ends
    /// the session. `attempt` starts at 1 and goes up after each wrong password, so the
    /// panel can say "Wrong password. Try again."
    case needsPassword(attempt: Int)
    /// Install was clicked: finishing staging at full speed, then moving into place.
    case installing(AppSummary, InstallProgress)
    case installed(URL)
    case cancelled
    case failed(InstallFailure)

    /// True when the session will never change state again.
    public var isFinal: Bool {
        switch self {
        case .installed, .cancelled, .failed, .refused, .cannotInstall: true
        case .reading, .needsLicence, .needsPassword, .preparing, .waitingToPrepare, .ready, .warning, .installing:
            false
        }
    }
}

/// What the licence screen shows about the app before the user agrees: read from the
/// image's catalog and the app's `Info.plist` and icon, which is reading, not installing.
/// Staging still waits for `acceptLicence()`.
public struct AppPreview: Sendable, Equatable {
    /// `CFBundleDisplayName`, else `CFBundleName`, else the folder name without `.app`.
    public var name: String
    public var version: String?
    /// Sum of the app's file sizes, from the catalog.
    public var size: UInt64
    /// The `.icns` named by `CFBundleIconFile`, as bytes (capped at `BundleInfo.maxIconSize`).
    /// Nil for apps whose icon lives only in an asset catalog.
    public var iconData: Data?

    public init(name: String, version: String?, size: UInt64, iconData: Data?) {
        self.name = name
        self.version = version
        self.size = size
        self.iconData = iconData
    }
}

/// Bytes of the app written so far. Coalesced to at most `InstallSession.progressSteps`
/// updates per stage, so the panel can bind to it directly.
public struct InstallProgress: Sendable, Equatable {
    public let bytesDone: UInt64
    public let bytesTotal: UInt64

    public init(bytesDone: UInt64, bytesTotal: UInt64) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// 0 to 1; an empty app counts as done.
    public var fraction: Double { bytesTotal == 0 ? 1 : Double(bytesDone) / Double(bytesTotal) }
}

/// What the panel says about the app. Built in two passes: what the image's catalog and
/// `Info.plist` tell before staging (shown at once), then what the staged copy's signature
/// and Gatekeeper tell.
public struct AppSummary: Sendable, Equatable {
    /// The bundle's folder name in the image, such as "Rectangle.app"; also its name once installed.
    public let bundleName: String
    /// `CFBundleDisplayName`, else `CFBundleName`, else the folder name without `.app`.
    public var name: String
    /// `CFBundleShortVersionString`, the version people know.
    public var version: String?
    public var bundleIdentifier: String?
    /// Sum of the app's file sizes, from the image's catalog.
    public var size: UInt64
    /// The `.icns` named by `CFBundleIconFile`, inside the staged copy. Nil until staged,
    /// and for apps whose icon lives only in an asset catalog.
    public var iconFile: URL?
    /// The signing certificate's organisation (or its common name when it has none).
    public var signer: String?
    public var teamID: String?
    /// Gatekeeper accepts it as checked by Apple (notarized, Apple's own, or App Store).
    public var isNotarized: Bool
    /// Set when an app of the same name is already in the destination.
    public var update: Update?

    public struct Update: Sendable, Equatable {
        public var installedVersion: String?
        /// Team ID comparison with the installed copy; nil until the new copy is checked.
        public var developer: DeveloperMatch?

        public init(installedVersion: String?, developer: DeveloperMatch?) {
            self.installedVersion = installedVersion
            self.developer = developer
        }
    }

    /// For the app's previews and demo fixtures; sessions build summaries themselves.
    public init(
        bundleName: String, name: String, version: String?, bundleIdentifier: String?, size: UInt64,
        iconFile: URL? = nil, signer: String? = nil, teamID: String? = nil, isNotarized: Bool = false,
        update: Update? = nil
    ) {
        self.bundleName = bundleName
        self.name = name
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.size = size
        self.iconFile = iconFile
        self.signer = signer
        self.teamID = teamID
        self.isNotarized = isNotarized
        self.update = update
    }
}

public enum CannotInstallReason: Sendable, Equatable {
    /// Only installer packages: the panel hands these to Installer.
    case packageOnly(names: [String])
    /// No `.app` and no package at the top level.
    case noApp
    /// More than one app (v2 scope).
    case multipleApps(names: [String])
    /// Names in the app that the destination volume can't keep apart (case or
    /// normalisation). `paths` are from the app's name down.
    case nameCollision(paths: [String])
    /// The image is damaged or not a disk image at all.
    case unreadable(String)
    /// Drop can't read the image and macOS wouldn't attach it either (the hidden mount's
    /// error, for diagnostics). The panel offers "Open disk image".
    case wontAttach(String)
    /// The image has a licence agreement Drop couldn't show before attaching (its container
    /// isn't readable), and Drop never accepts one unseen. "Open disk image" lets macOS show it.
    case licenceNotShown
}

/// Why a session stopped with `failed`.
public enum InstallFailure: Error, Sendable, Equatable {
    case extractor(ExtractorError)
    case reader(ReaderError)
    case other(String)

    init(_ error: any Error) {
        switch error {
        case let error as ExtractorError: self = .extractor(error)
        case let error as ReaderError: self = .reader(error)
        default: self = .other(String(describing: error))
        }
    }
}

/// How long each phase took, for diagnostics and the background-impact benchmark.
/// Seconds from `start()`; nil for phases not reached.
public struct InstallTimings: Sendable, Equatable {
    public var opened: Double?
    public var stagingStarted: Double?
    public var staged: Double?
    public var verified: Double?
    /// When `install()` boosted a stage in progress.
    public var boosted: Double?
    /// Hidden mount only: when the image was attached, and when it was detached again.
    public var mounted: Double?
    public var unmounted: Double?
}
