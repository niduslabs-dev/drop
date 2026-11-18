import Foundation
import Observation
import os

/// A newer Drop found in the appcast, reduced to what Drop's surfaces show.
struct AvailableUpdate: Equatable, Sendable {
    /// The version people see ("1.1"), the appcast item's display version.
    let version: String
    /// The download's size in bytes, when the appcast gives one.
    let size: UInt64?
    /// Every release-note line from the item's description. The popup shows the first
    /// `ReleaseNotes.popupLimit`; What's new shows them all.
    let notes: [String]
    /// Where Release notes goes: the GitHub release page.
    let releaseNotesURL: URL?
}

/// What the user can do on the popup and in Settings' version row.
enum UpdateAction: Equatable, Sendable {
    /// Restart to update: install now and reopen Drop.
    case restart
    /// Later: hide the popup. A downloaded update installs the next time Drop quits.
    case later
    /// Download, shown when Install updates automatically is off.
    case download
    /// Check for updates in Settings.
    case check
    /// Try again after a failure the row shows: checks again, then downloads when the
    /// failure was a download or a verification.
    case retry
}

/// Where an action came from. Only a cycle started in Settings reports its failures, and
/// it never raises the popup (the version row shows every step).
enum UpdateSurface: Equatable, Sendable {
    case settings
    case popup
}

/// How Sparkle wants an answer to a prompt, kept until the user picks one. Mirrors
/// `SPUUserUpdateChoice`, so the model stays testable without Sparkle.
enum UpdateReply: Equatable, Sendable {
    case install
    case dismiss
}

/// A failure the version row reports. Only for a cycle started in Settings; a background
/// check fails silently and Sparkle retries the next day.
enum UpdateFailure: Equatable, Sendable {
    /// "Couldn't check for updates."
    case check
    /// "Couldn't download 1.1."
    case download(AvailableUpdate)
    /// "Couldn't verify 1.1.": Sparkle couldn't unpack it or a signature didn't match.
    case verify(AvailableUpdate)
    /// "Couldn't restart. It installs on quit.": Restart after Later re-checks first, and
    /// that check failed (offline). The update is still on disk.
    case restart(AvailableUpdate)
}

/// The state behind every update surface: the popup and Settings' version row.
/// `UpdateDriver` feeds it Sparkle's events; the views send the user's choices back through
/// `perform(_:from:)`.
///
/// Rules (the Updates and UpdatesInRow boards):
/// - A background check downloads silently when Install updates automatically is on, then
///   the popup says the update is ready. Off, the popup asks with Download first.
/// - The popup is never on screen with Settings: opening Settings closes it (the pending
///   reply stays, so the row's buttons answer it), and nothing raises it while Settings is
///   open. A cycle started in Settings never raises it at all.
/// - Later hides the popup and keeps the update pending: Sparkle installs it when Drop
///   quits, and the row says so.
/// - Failures of a cycle started in Settings show in the row with Try again. Any other
///   failure is logged only; Sparkle's daily schedule is the retry. A ready update stays
///   ready through any failure.
@MainActor
@Observable
final class UpdateModel {
    enum Phase: Equatable {
        /// Nothing pending.
        case idle
        /// A check the user started is running.
        case checking
        /// A newer version is out but not downloaded (automatic installs off).
        case available(AvailableUpdate)
        /// Downloading. `fraction` is nil until the length is known (and for a feed item
        /// without one).
        case downloading(AvailableUpdate, fraction: Double?)
        /// Downloaded; Sparkle unpacks it and checks both signatures.
        case preparing(AvailableUpdate)
        /// Downloaded and verified: installs on quit, or now with Restart to update.
        /// `afterLater` once Later was pressed on the popup.
        case ready(AvailableUpdate, afterLater: Bool)
        /// Sparkle is quitting Drop to install (or re-checking first, after Later).
        case installing(AvailableUpdate?)
        /// A failure the row shows.
        case failed(UpdateFailure)
    }

    /// The running version ("1.0"), the left side of "1.0 → 1.1".
    let currentVersion: String
    private(set) var phase = Phase.idle
    /// The popup is wanted. The window controller shows it when no install panel is up.
    private(set) var wantsPopup = false
    /// When Sparkle last finished a check, from `SPUUpdater.lastUpdateCheckDate`.
    var lastChecked: Date?
    /// "Install updates automatically". The controller mirrors it into Sparkle, which
    /// stores it (`SUAutomaticallyUpdate`).
    var automatic: Bool {
        didSet {
            guard automatic != oldValue else { return }
            automaticChanged(automatic)
        }
    }
    /// False when no updater runs (debug and test launches): Check for updates is disabled.
    var isEnabled: Bool
    /// Settings is on screen. Opening it closes the popup; while it's open the popup never
    /// shows and the version row shows the update instead.
    var settingsOpen = false {
        didSet { if settingsOpen { wantsPopup = false } }
    }
    /// The first launch after an update: the row says "Updated to x" until Settings has been
    /// open once (`LastRunVersion`).
    var justUpdated = false

    /// Answers Sparkle's open prompt (update found, ready to install), if one is waiting.
    @ObservationIgnored private var pendingReply: ((UpdateReply) -> Void)?
    /// Sparkle's install-now handler for an update it downloaded in the background. Can be
    /// called more than once.
    @ObservationIgnored private var installNow: (() -> Void)?
    /// Restart to update was pressed with nothing to call: the next prompt for this update
    /// is answered with install straight away.
    @ObservationIgnored private var restartRequested = false
    /// Download or Try again was pressed with no prompt to answer: the check it starts
    /// downloads what it finds, whatever the automatic switch says.
    @ObservationIgnored private var downloadRequested = false
    /// The current cycle was started in Settings: it never raises the popup, and its
    /// failures show in the row.
    @ObservationIgnored private var startedInSettings = false

    /// Starts a user-initiated check (`SPUUpdater.checkForUpdates`).
    @ObservationIgnored var requestCheck: () -> Void = {}
    @ObservationIgnored var automaticChanged: (Bool) -> Void = { _ in }
    /// Opens a URL (Release notes); `NSWorkspace` in the app.
    @ObservationIgnored var openURL: (URL) -> Void = { _ in }
    /// The bundled RELEASE_NOTES.md, for What's new.
    @ObservationIgnored var bundledNotes: [ReleaseNotesFile.Section] = ReleaseNotesFile.bundled()

    init(currentVersion: String, automatic: Bool = true, isEnabled: Bool = false) {
        self.currentVersion = currentVersion
        self.automatic = automatic
        self.isEnabled = isEnabled
    }

    /// How long a check reads "checked just now".
    static let justNow: TimeInterval = 60

    /// The update the surfaces describe, whatever its phase.
    var update: AvailableUpdate? {
        switch phase {
        case .available(let update), .downloading(let update, _), .preparing(let update), .ready(let update, _):
            update
        case .installing(let update): update
        case .failed(.restart(let update)): update
        case .idle, .checking, .failed: nil
        }
    }

    /// Downloaded and waiting for a restart (also after a failed Restart, which still
    /// installs on quit).
    var isReady: Bool {
        switch phase {
        case .ready, .failed(.restart): true
        default: false
        }
    }

    // MARK: User actions

    func perform(_ action: UpdateAction, from surface: UpdateSurface = .settings) {
        switch action {
        case .restart:
            wantsPopup = false
            let update = update
            if let installNow {
                phase = .installing(update)
                installNow()
            } else if let reply = takeReply() {
                phase = .installing(update)
                reply(.install)
            } else {
                // After Later the prompt was answered; a new check brings the pending update
                // back as a prompt, answered with install (`found`).
                startedInSettings = surface == .settings
                restartRequested = true
                phase = .installing(update)
                requestCheck()
            }
        case .later:
            wantsPopup = false
            if case .ready(let update, _) = phase { phase = .ready(update, afterLater: true) }
            takeReply()?(.dismiss)
        case .download:
            wantsPopup = false
            startedInSettings = surface == .settings
            guard case .available(let update) = phase, let reply = takeReply() else {
                downloadRequested = true
                if let update { phase = .downloading(update, fraction: nil) }
                requestCheck()
                return
            }
            phase = .downloading(update, fraction: nil)
            reply(.install)
        case .check:
            guard isEnabled else { return }
            startedInSettings = surface == .settings
            requestCheck()
        case .retry:
            guard case .failed(let failure) = phase else { return }
            switch failure {
            case .check:
                phase = .idle
                perform(.check, from: surface)
            case .download, .verify:
                startedInSettings = surface == .settings
                downloadRequested = true
                phase = .checking
                requestCheck()
            case .restart:
                perform(.restart, from: surface)
            }
        }
    }

    func openReleaseNotes() {
        if let url = update?.releaseNotesURL { openURL(url) }
    }

    // MARK: Sparkle's events (`UpdateDriver`)

    /// The user started a check.
    func checkStarted() {
        switch phase {
        case .idle, .failed(.check): phase = .checking
        default: break
        }
    }

    /// Sparkle found `update`. `downloaded` is true when it's already on disk (a background
    /// download, or the installer is armed for quit); `userInitiated` is a check the user
    /// started.
    func found(_ update: AvailableUpdate, downloaded: Bool, userInitiated: Bool, reply: @escaping (UpdateReply) -> Void)
    {
        if downloaded {
            if restartRequested {
                restartRequested = false
                phase = .installing(update)
                reply(.install)
                return
            }
            phase = .ready(update, afterLater: false)
            pendingReply = reply
            raisePopup()
        } else if automatic || downloadRequested {
            // A check the user started downloads straight away, as a background check would
            // have; so does one started by Download or Try again.
            downloadRequested = false
            phase = .downloading(update, fraction: nil)
            reply(.install)
        } else {
            phase = .available(update)
            pendingReply = reply
            raisePopup()
        }
    }

    /// The download started.
    func downloadStarted() {
        if case .downloading(let update, _) = phase { phase = .downloading(update, fraction: nil) }
    }

    /// How much of the download has arrived, 0 to 1. Changes the phase only when the whole
    /// percentage changes, so the row redraws once per step.
    func downloadProgressed(_ fraction: Double) {
        guard case .downloading(let update, let old) = phase else { return }
        let clamped = min(max(fraction, 0), 1)
        if let old, Self.percent(old) == Self.percent(clamped) { return }
        phase = .downloading(update, fraction: clamped)
    }

    /// Sparkle is unpacking the download and checking its signatures.
    func preparing() {
        if case .downloading(let update, _) = phase { phase = .preparing(update) }
    }

    /// Sparkle downloaded and unpacked the update the user chose to download.
    func readyToInstall(reply: @escaping (UpdateReply) -> Void) {
        guard let update else {
            reply(.dismiss)
            return
        }
        if restartRequested {
            restartRequested = false
            phase = .installing(update)
            reply(.install)
            return
        }
        phase = .ready(update, afterLater: false)
        pendingReply = reply
        raisePopup()
    }

    /// A background download finished and Sparkle will install it on quit; `installNow`
    /// installs and relaunches at once (`updater(_:willInstallUpdateOnQuit:…)`).
    func readyOnQuit(_ update: AvailableUpdate, installNow: @escaping () -> Void) {
        self.installNow = installNow
        phase = .ready(update, afterLater: false)
        raisePopup()
    }

    /// A check found nothing newer.
    func notFound() {
        switch phase {
        case .checking, .failed(.check): phase = .idle
        default: break
        }
        restartRequested = false
        downloadRequested = false
    }

    /// Sparkle is installing (Drop is about to quit).
    func installing() {
        wantsPopup = false
        phase = .installing(update)
    }

    /// Sparkle stopped the current cycle (`dismissUpdateInstallation`). A downloaded update
    /// still installs on quit, and a failure stays in the row; anything in flight is dropped.
    func cycleEnded() {
        pendingReply = nil
        startedInSettings = false
        switch phase {
        case .ready, .available, .installing, .failed: break
        case .idle, .checking, .downloading, .preparing: phase = .idle
        }
    }

    /// Any failure, always logged. A cycle started in Settings shows it in the row; any
    /// other goes back to idle, and Sparkle tries again on its next daily check. A ready
    /// update stays ready.
    func failed(_ error: any Error) {
        Log.updates.error("Update failed: \(error.localizedDescription, privacy: .public)")
        let restarting = restartRequested
        restartRequested = false
        downloadRequested = false
        pendingReply = nil
        if case .ready = phase { return }
        guard startedInSettings else {
            if case .failed(.restart) = phase { return }
            phase = .idle
            wantsPopup = false
            return
        }
        switch phase {
        case .ready, .failed: break
        case .idle, .checking: phase = .failed(.check)
        case .available(let update), .downloading(let update, _): phase = .failed(.download(update))
        case .preparing(let update): phase = .failed(.verify(update))
        case .installing(let update):
            if let update { phase = .failed(restarting ? .restart(update) : .verify(update)) } else { phase = .idle }
        }
        wantsPopup = false
    }

    /// The popup comes up for this cycle unless it was started in Settings or Settings is
    /// open, where the row shows it.
    private func raisePopup() {
        wantsPopup = !startedInSettings && !settingsOpen
    }

    @discardableResult
    private func takeReply() -> ((UpdateReply) -> Void)? {
        defer { pendingReply = nil }
        return pendingReply
    }

    static func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded(.down)) }

    #if DEBUG
        /// Sets a phase directly, for `--demo` screenshots.
        func demo(_ phase: Phase, popup: Bool) {
            self.phase = phase
            wantsPopup = popup
        }
    #endif
}

// MARK: - Copy

extension UpdateModel {
    /// Drop's name in the row's and the sheet's copy.
    static let appName = "Drop"

    /// The version row (UpdatesInRow board): its line, its button and What's new, for each
    /// phase. `locale` and `calendar` are parameters so tests pin the clock format.
    func row(now: Date = .now, locale: Locale = .current, calendar: Calendar = .current) -> UpdateRowContent {
        let name = Self.appName
        var row = UpdateRowContent(
            title: "Version \(currentVersion)", caption: "", button: "Check for updates",
            buttonAccessibilityLabel: "Check for updates",
            whatsNewAccessibilityLabel: "What's new in \(name) \(currentVersion)")
        if let pending = notesUpdate, isReadyLike {
            row.whatsNewAccessibilityLabel = "What's new in \(name) \(pending.version)"
        }
        func restart(_ update: AvailableUpdate, enabled: Bool) {
            row.button = "Restart to update"
            row.buttonKind = .primary
            row.buttonEnabled = enabled
            row.buttonAccessibilityLabel = "Restart to update to \(name) \(update.version)"
        }
        func tryAgain() {
            row.button = "Try again"
            row.buttonAccessibilityLabel = "Try again"
            row.isError = true
        }
        switch phase {
        case .idle:
            guard isEnabled else {
                row.caption = "Updates are off in test builds."
                row.buttonEnabled = false
                row.showsWhatsNew = false
                return row
            }
            if justUpdated {
                row.caption = "Updated to \(currentVersion)"
            } else if let lastChecked {
                let phrase = Self.checkedPhrase(lastChecked, now: now, locale: locale, calendar: calendar)
                row.caption = "Up to date \u{00B7} checked " + phrase
                if let at = phrase.range(of: " at ") {
                    row.shortCaption = "Up to date \u{00B7} checked " + phrase[..<at.lowerBound]
                }
            } else {
                row.caption = "Not checked yet"
            }
        case .checking:
            row.caption = "Checking for updates\u{2026}"
            row.lead = .spinner
            row.buttonEnabled = false
        case .available(let update):
            row.caption = "Version \(update.version) is available"
            row.button = "Download"
            row.buttonAccessibilityLabel = "Download \(name) \(update.version)"
        case .downloading(let update, let fraction):
            if let fraction {
                row.caption = "Downloading \(update.version)"
                row.percent = Self.percent(fraction)
            } else {
                row.caption = "Downloading \(update.version)\u{2026}"
            }
            restart(update, enabled: false)
        case .preparing(let update):
            row.caption = "Preparing \(update.version)\u{2026}"
            row.lead = .spinner
            restart(update, enabled: false)
        case .ready(let update, let afterLater):
            row.caption =
                afterLater ? "\(update.version) installs when \(name) quits" : "Version \(update.version) is ready"
            restart(update, enabled: true)
        case .installing(let update):
            row.caption = update.map { "Installing \($0.version)\u{2026}" } ?? "Installing\u{2026}"
            row.lead = .spinner
            if let update { restart(update, enabled: false) } else { row.buttonEnabled = false }
        case .failed(.check):
            row.caption = "Couldn't check for updates."
            tryAgain()
        case .failed(.download(let update)):
            row.caption = "Couldn't download \(update.version)."
            tryAgain()
        case .failed(.verify(let update)):
            row.caption = "Couldn't verify \(update.version)."
            tryAgain()
        case .failed(.restart(let update)):
            row.caption = "Couldn't restart. It installs on quit."
            row.isError = true
            restart(update, enabled: true)
        }
        return row
    }

    /// What the row's capsule does in this phase.
    var rowAction: UpdateAction {
        switch phase {
        case .idle, .checking: .check
        case .available: .download
        case .downloading, .preparing, .ready, .installing, .failed(.restart): .restart
        case .failed: .retry
        }
    }

    /// What's new's All release notes.
    static let allReleaseNotesURL = URL(string: "https://niduslabs.dev/drop/releases")!

    /// Ready, or past ready: What's new is named for the pending version and its group is
    /// tagged "Ready to install".
    private var isReadyLike: Bool {
        switch phase {
        case .ready, .installing, .failed(.restart): true
        default: false
        }
    }

    /// The update whose notes lead What's new: found, downloading, ready and after.
    var notesUpdate: AvailableUpdate? {
        switch phase {
        case .available, .downloading, .preparing, .ready, .installing, .failed(.restart): update
        default: nil
        }
    }

    /// What's new's groups, newest first: the pending update's lines from the feed, then
    /// the installed version and every older one from the bundled RELEASE_NOTES.md.
    func releaseNoteGroups(bundled: [ReleaseNotesFile.Section]) -> [ReleaseNoteGroup] {
        var groups: [ReleaseNoteGroup] = []
        if let pending = notesUpdate, !pending.notes.isEmpty {
            groups.append(
                ReleaseNoteGroup(
                    version: pending.version, tag: isReadyLike ? "Ready to install" : nil, lines: pending.notes))
        }
        for section in bundled where !section.lines.isEmpty {
            guard !ReleaseNotesFile.isNewer(section.version, than: currentVersion),
                section.version != notesUpdate?.version
            else { continue }
            groups.append(
                ReleaseNoteGroup(
                    version: section.version, tag: section.version == currentVersion ? "Installed" : nil,
                    lines: section.lines))
        }
        return groups
    }

    /// "just now" for a minute, then "today at 09:12", "yesterday at 18:40" or "on 12 Nov".
    static func checkedPhrase(_ date: Date, now: Date, locale: Locale, calendar: Calendar) -> String {
        let age = now.timeIntervalSince(date)
        if age >= 0, age < justNow { return "just now" }
        var calendar = calendar
        calendar.locale = locale
        let time = date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "yesterday at \(time)"
        }
        let day = date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
        return "on \(day)"
    }

    /// "Drop 1.1 is ready" or, before downloading, "Drop 1.1 is available".
    var popupTitle: String {
        guard let update else { return "Drop" }
        if case .available = phase { return "Drop \(update.version) is available" }
        return "Drop \(update.version) is ready"
    }

    /// The size part of "1.0 → 1.1 · 4 MB, downloaded".
    var sizeDetail: String? {
        guard let update else { return nil }
        let downloaded = isReady ? "downloaded" : nil
        let parts = [update.size.map(Format.size), downloaded].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Release-note lines from an appcast item's description, which is HTML (a
/// `<ul>` from the release workflow) or plain lines.
enum ReleaseNotes {
    /// The popup shows this many lines; What's new shows every line.
    static let popupLimit = 3

    /// The list items, or else the non-empty lines, with tags and list markers removed and
    /// the common entities decoded; at most `limit` of them.
    static func lines(from description: String?, limit: Int = .max) -> [String] {
        guard let description, !description.isEmpty else { return [] }
        let items = matches(of: #"<li[^>]*>(.*?)</li>"#, in: description)
        let raw: [String]
        if items.isEmpty {
            let breaks = description.replacingOccurrences(
                of: #"<\s*(br|/p|/div|/h[1-6])\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            raw = breaks.components(separatedBy: .newlines)
        } else {
            raw = items
        }
        let cleaned = raw.map(clean).filter { !$0.isEmpty }
        return Array(cleaned.prefix(limit))
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = text.first, "-*\u{2022}".contains(marker) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

extension Log {
    static let updates = Logger(subsystem: "dev.niduslabs.drop", category: "updates")
}

/// Remembers the last version that ran, for the row's "Updated to x" (UpdatesInRow board):
/// the first launch of a newer version sets a notice that stays until Settings has been open
/// once. A copy from before this existed (no version stored) counts as updated when
/// onboarding has run before, so 1.0.5 to 1.0.6 says so too; a fresh install never does.
enum LastRunVersion {
    static let versionKey = "lastRunVersion"
    static let noticeKey = "updatedNotice"

    /// Records `current` as run and returns whether the row should say "Updated to current".
    static func launched(_ current: String, defaults: UserDefaults, hasRunBefore: Bool) -> Bool {
        let last = defaults.string(forKey: versionKey)
        defaults.set(current, forKey: versionKey)
        if let last {
            if ReleaseNotesFile.isNewer(current, than: last) { defaults.set(current, forKey: noticeKey) }
        } else if hasRunBefore {
            defaults.set(current, forKey: noticeKey)
        }
        return defaults.string(forKey: noticeKey) == current
    }

    /// Settings has been open once: the row goes back to its usual line.
    static func noticeSeen(defaults: UserDefaults) {
        defaults.removeObject(forKey: noticeKey)
    }
}
