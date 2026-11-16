import AppKit
import DiskImage
import Installer
import Observation
import SwiftUI
import Verifier

/// Everything a button on the panel can ask for. The views only send these; the
/// controller (or the demo) decides what they do.
enum PanelAction: Sendable, Equatable {
    case install
    case installAnyway
    case notNow
    case close
    case cancelInstall
    case openImage
    case openInstaller
    case showImageInFinder
    case showAppInFinder
    case openApp
    case undoTrash
    case agreeLicence
    case disagreeLicence
    case saveLicence
    case submitPassword
    case changeLocation(InstallLocation)
}

/// Which approved board the panel is showing.
enum Board: Equatable {
    case main
    case installing
    case done
    case update
    case warning
    case refused
    case fallback
    case licence
    case password
    case hidden
}

/// What the panel draws in the icon slot: the app's own icon once known, or a tile.
enum PanelIcon {
    case image(NSImage)
    /// A coloured tile with a symbol, for demo fixtures.
    case tile(Color, symbol: String)
    /// The grey tile on the Fallback and Password boards.
    case placeholder(symbol: String)
}

/// One DMG's panel: the session's latest state plus the choices made on the panel.
@MainActor
@Observable
final class PanelModel: Identifiable {
    enum Origin: Equatable {
        /// Found by the watcher in the folder with this name ("New in Downloads").
        case watched(folderName: String)
        /// Opened explicitly: Open With, a double-click when Drop is the default, or dropped
        /// on the app icon. Shown in the centred window, which takes focus.
        case opened
    }

    let id = UUID()
    let dmg: URL
    let origin: Origin
    var state: InstallState = .reading {
        didSet {
            if let summary = state.summary { self.summary = summary }
            if case .needsLicence(_, let preview?) = state { self.preview = preview }
            if case .installed = state, installDuration == nil, let installStartedAt {
                installDuration = ContinuousClock.now - installStartedAt
            }
        }
    }
    /// What the image said about the app before the licence was agreed to.
    private(set) var preview: AppPreview?
    /// When Install was clicked, and how long it took until installed, for the install
    /// window's "Installed in Applications · 1.2 s".
    var installStartedAt: ContinuousClock.Instant?
    var installDuration: Duration?
    /// Install was clicked with so little work left (`Theme.Motion.skipProgressBelow`) that
    /// the button goes straight to done instead of showing a fill that would only flash.
    var skipsProgress = false
    /// The first staging progress seen and when, to estimate how long the rest will take.
    @ObservationIgnored private var firstProgress: (at: ContinuousClock.Instant, bytes: UInt64)?

    /// Notes staging progress for `estimatedRemaining`.
    func noteProgress() {
        guard let progress, firstProgress == nil else { return }
        firstProgress = (.now, progress.bytesDone)
    }

    /// How long the rest of staging should take, from the rate seen so far: the background
    /// rate, which Install only raises, so the estimate errs towards showing progress. Nil
    /// before there's a rate to go on. Zero once staged and checked.
    var estimatedRemaining: Duration? {
        switch state {
        case .ready, .warning: return .zero
        default: break
        }
        guard let progress, let firstProgress, progress.bytesDone > firstProgress.bytes else { return nil }
        let elapsed = ContinuousClock.now - firstProgress.at
        let rate = Double(progress.bytesDone - firstProgress.bytes) / max(elapsed.seconds, .leastNonzeroMagnitude)
        return .seconds(Double(progress.bytesTotal - progress.bytesDone) / rate)
    }
    /// The latest summary seen, kept across states that carry none (installed, failed).
    private(set) var summary: AppSummary?
    var location: InstallLocation
    /// Where the destination is shown as, such as "Applications". Set from `--destination`
    /// in tests so the copy matches what really happens.
    var destinationName: String
    var trashImage: Bool
    /// Where the disk image went after install, for Undo.
    var trashedImage: URL?
    var installedApp: URL?
    /// The installed copy of the app being updated is running (Update board).
    var appIsRunning = false
    /// Quit and Update asked the app to quit and it didn't.
    var quitFailed = false
    var licenceAccepted = false
    /// Agree and Install was clicked: install as soon as the session can.
    var installWhenReady = false
    /// Quit and Update quit the running copy: open the new one once installed.
    var reopenAfterInstall = false
    var licenceLanguage = 0
    var password = ""
    /// Set while a button's work runs, so it can't be pressed twice.
    var isBusy = false
    /// The pointer is over the panel: board 3 waits before closing.
    var isHovered = false
    /// Demo fixtures set this; real sessions use the app's icon.
    var iconOverride: PanelIcon?

    @ObservationIgnored var send: (PanelAction) -> Void = { _ in }

    init(dmg: URL, origin: Origin, location: InstallLocation, trashImage: Bool) {
        self.dmg = dmg
        self.origin = origin
        self.location = location
        self.destinationName = location.shortName
        self.trashImage = trashImage
    }

    var board: Board {
        switch state {
        case .reading: summary?.update == nil ? .main : .update
        case .needsLicence: .licence
        case .needsPassword: .password
        case .preparing, .waitingToPrepare, .ready: summary?.update == nil ? .main : .update
        case .installing: .installing
        case .installed: .done
        case .warning: .warning
        case .refused: .refused
        case .cannotInstall, .failed: .fallback
        case .cancelled: .hidden
        }
    }

    /// The app's name for copy: from the app itself once read (or from the licence
    /// screen's preview), else a cleaned guess from the file name, for images Drop can only
    /// read by mounting (locked, mount-only) whose licence and password come first.
    var appName: String { summary?.name ?? preview?.name ?? ImageName.appName(fromImage: dmg) }

    /// True while staging and the check still run: the signer line isn't known yet.
    var isChecking: Bool {
        switch state {
        case .reading, .preparing, .waitingToPrepare: true
        default: false
        }
    }

    var progress: InstallProgress? {
        switch state {
        case .preparing(_, let progress), .installing(_, let progress): progress
        default: nil
        }
    }

    var icon: PanelIcon {
        if let iconOverride { return iconOverride }
        if let installedApp { return .image(NSWorkspace.shared.icon(forFile: installedApp.path)) }
        if let file = summary?.iconFile, let image = NSImage(contentsOf: file) { return .image(image) }
        if let data = preview?.iconData, let image = NSImage(data: data) { return .image(image) }
        switch board {
        case .fallback: return .placeholder(symbol: "externaldrive")
        case .password: return .placeholder(symbol: "lock")
        default: return .image(NSWorkspace.shared.icon(for: .applicationBundle))
        }
    }
}

extension InstallState {
    var summary: AppSummary? {
        switch self {
        case .preparing(let summary, _), .waitingToPrepare(let summary), .ready(let summary),
            .warning(let summary, _), .refused(let summary, _), .installing(let summary, _):
            summary
        case .reading, .needsLicence, .cannotInstall, .needsPassword, .installed, .cancelled, .failed: nil
        }
    }
}

enum Format {
    /// "84 MB", in decimal units as Finder shows.
    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// "44 of 84 MB": both in the total's unit.
    static func progress(_ progress: InstallProgress) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let total = formatter.string(fromByteCount: Int64(clamping: progress.bytesTotal))
        formatter.includesUnit = false
        let done = formatter.string(fromByteCount: Int64(clamping: progress.bytesDone))
        return "\(done) of \(total)"
    }

    /// "2 min ago", "Yesterday".
    static func relative(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now).capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Duration {
    /// The duration in seconds, as a `Double`.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
