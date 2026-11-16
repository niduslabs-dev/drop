import Foundation
import Observation
import os

/// A newer Drop found in the appcast, reduced to what Drop's surfaces show.
struct AvailableUpdate: Equatable, Sendable {
    /// The version people see ("1.1"), the appcast item's display version.
    let version: String
    /// The download's size in bytes, when the appcast gives one.
    let size: UInt64?
    /// Up to `ReleaseNotes.lineLimit` lines from the item's description.
    let notes: [String]
    /// Where Release notes goes: the GitHub release page.
    let releaseNotesURL: URL?
}

/// What the user can do on the popup and in Settings.
enum UpdateAction: Equatable, Sendable {
    /// Restart to Update: install now and reopen Drop.
    case restart
    /// Later: hide the popup. A downloaded update installs the next time Drop quits.
    case later
    /// Download, shown when Install updates automatically is off.
    case download
    /// Check for Updates in Settings.
    case check
}

/// How Sparkle wants an answer to a prompt, kept until the user picks one. Mirrors
/// `SPUUserUpdateChoice`, so the model stays testable without Sparkle.
enum UpdateReply: Equatable, Sendable {
    case install
    case dismiss
}

/// The state behind every update surface: the popup, the Settings banner and the Drop
/// group's version caption. `UpdateDriver` feeds it Sparkle's events; the views send the
/// user's choices back through `perform(_:)`.
///
/// Rules (the Updates board):
/// - A background check downloads silently when Install updates automatically is on, then
///   the popup says the update is ready. Off, the popup asks with Download first.
/// - Later hides the popup and keeps the update pending: Sparkle installs it when Drop quits,
///   and the Settings banner stays until then.
/// - Failures are logged, never shown. Sparkle's daily schedule is the retry.
@MainActor
@Observable
final class UpdateModel {
    enum Phase: Equatable {
        /// Nothing pending.
        case idle
        /// A check the user started (Check for Updates) is running.
        case checking
        /// A newer version is out but not downloaded (automatic installs off).
        case available(AvailableUpdate)
        /// Downloading or unpacking, after Download or a check with automatic installs on.
        case downloading(AvailableUpdate)
        /// Downloaded and verified: installs on quit, or now with Restart to Update.
        case ready(AvailableUpdate)
        /// Sparkle is quitting Drop to install.
        case installing
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
    /// False when no updater runs (debug and test launches): Check for Updates is disabled.
    var isEnabled: Bool

    /// Answers Sparkle's open prompt (update found, ready to install), if one is waiting.
    @ObservationIgnored private var pendingReply: ((UpdateReply) -> Void)?
    /// Sparkle's install-now handler for an update it downloaded in the background. Can be
    /// called more than once.
    @ObservationIgnored private var installNow: (() -> Void)?
    /// Restart to Update was pressed with nothing to call: the next prompt for this update
    /// is answered with install straight away.
    @ObservationIgnored private var restartRequested = false

    /// Starts a user-initiated check (`SPUUpdater.checkForUpdates`).
    @ObservationIgnored var requestCheck: () -> Void = {}
    @ObservationIgnored var automaticChanged: (Bool) -> Void = { _ in }
    /// Opens a URL (Release notes); `NSWorkspace` in the app.
    @ObservationIgnored var openURL: (URL) -> Void = { _ in }

    init(currentVersion: String, automatic: Bool = true, isEnabled: Bool = false) {
        self.currentVersion = currentVersion
        self.automatic = automatic
        self.isEnabled = isEnabled
    }

    /// The update the surfaces describe, whatever its phase.
    var update: AvailableUpdate? {
        switch phase {
        case .available(let update), .downloading(let update), .ready(let update): update
        case .idle, .checking, .installing: nil
        }
    }

    /// Downloaded and waiting: the Settings banner shows.
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    // MARK: User actions

    func perform(_ action: UpdateAction) {
        switch action {
        case .restart:
            wantsPopup = false
            if let installNow {
                phase = .installing
                installNow()
            } else if let reply = takeReply() {
                phase = .installing
                reply(.install)
            } else {
                // After Later the prompt was answered; a new check brings the pending update
                // back as a prompt, answered with install (`found`).
                restartRequested = true
                requestCheck()
            }
        case .later:
            wantsPopup = false
            takeReply()?(.dismiss)
        case .download:
            wantsPopup = false
            guard case .available(let update) = phase, let reply = takeReply() else {
                requestCheck()
                return
            }
            phase = .downloading(update)
            reply(.install)
        case .check:
            guard isEnabled else { return }
            requestCheck()
        }
    }

    func openReleaseNotes() {
        if let url = update?.releaseNotesURL { openURL(url) }
    }

    // MARK: Sparkle's events (`UpdateDriver`)

    /// The user started a check.
    func checkStarted() {
        if case .idle = phase { phase = .checking }
    }

    /// Sparkle found `update`. `downloaded` is true when it's already on disk (a background
    /// download, or the installer is armed for quit); `userInitiated` is a Check for Updates.
    func found(_ update: AvailableUpdate, downloaded: Bool, userInitiated: Bool, reply: @escaping (UpdateReply) -> Void)
    {
        if downloaded {
            if restartRequested {
                restartRequested = false
                phase = .installing
                reply(.install)
                return
            }
            phase = .ready(update)
            pendingReply = reply
            wantsPopup = true
        } else if automatic {
            // Automatic installs on: a check the user started downloads straight away, as a
            // background check would have.
            phase = .downloading(update)
            reply(.install)
        } else {
            phase = .available(update)
            pendingReply = reply
            wantsPopup = true
        }
    }

    /// Sparkle downloaded and unpacked the update the user chose to download.
    func readyToInstall(reply: @escaping (UpdateReply) -> Void) {
        guard let update else {
            reply(.dismiss)
            return
        }
        if restartRequested {
            restartRequested = false
            phase = .installing
            reply(.install)
            return
        }
        phase = .ready(update)
        pendingReply = reply
        wantsPopup = true
    }

    /// A background download finished and Sparkle will install it on quit; `installNow`
    /// installs and relaunches at once (`updater(_:willInstallUpdateOnQuit:…)`).
    func readyOnQuit(_ update: AvailableUpdate, installNow: @escaping () -> Void) {
        self.installNow = installNow
        phase = .ready(update)
        wantsPopup = true
    }

    /// A check the user started found nothing newer.
    func notFound() {
        if case .checking = phase { phase = .idle }
        restartRequested = false
    }

    /// Sparkle is installing (Drop is about to quit).
    func installing() {
        wantsPopup = false
        phase = .installing
    }

    /// Sparkle stopped the current cycle (`dismissUpdateInstallation`). A downloaded update
    /// still installs on quit, so the banner stays; anything in flight is dropped.
    func cycleEnded() {
        pendingReply = nil
        switch phase {
        case .ready, .available, .installing: break
        case .idle, .checking, .downloading: phase = .idle
        }
    }

    /// Any failure: logged, never shown. A pending download stays pending; anything else
    /// goes back to idle and Sparkle tries again on its next daily check.
    func failed(_ error: any Error) {
        Log.updates.error("Update failed: \(error.localizedDescription, privacy: .public)")
        restartRequested = false
        pendingReply = nil
        switch phase {
        case .ready: break
        case .idle, .checking, .available, .downloading, .installing:
            phase = .idle
            wantsPopup = false
        }
    }

    @discardableResult
    private func takeReply() -> ((UpdateReply) -> Void)? {
        defer { pendingReply = nil }
        return pendingReply
    }

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
    /// The caption under "Version x" in Settings: "Up to date · checked today at 09:12",
    /// "1.1 downloaded · checked today at 09:12", and so on. `locale` and `calendar` are
    /// parameters so tests pin the clock format.
    func versionCaption(now: Date = .now, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let checked =
            lastChecked.map {
                " \u{00B7} checked " + Self.checkedPhrase($0, now: now, locale: locale, calendar: calendar)
            } ?? ""
        switch phase {
        case .checking: return "Checking\u{2026}"
        case .installing: return "Installing\u{2026}"
        case .downloading(let update): return "Downloading \(update.version)\u{2026}"
        case .ready(let update): return "\(update.version) downloaded" + checked
        case .available(let update): return "\(update.version) available" + checked
        case .idle:
            guard isEnabled else { return "Updates are off in test builds." }
            return lastChecked == nil ? "Not checked yet" : "Up to date" + checked
        }
    }

    /// "today at 09:12", "yesterday at 18:40" or "on 12 Nov".
    static func checkedPhrase(_ date: Date, now: Date, locale: Locale, calendar: Calendar) -> String {
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

/// Release-note lines for the popup from an appcast item's description, which is HTML (a
/// `<ul>` from the release workflow) or plain lines.
enum ReleaseNotes {
    static let lineLimit = 3

    /// The first `limit` list items, or else the first non-empty lines, with tags and list
    /// markers removed and the common entities decoded.
    static func lines(from description: String?, limit: Int = lineLimit) -> [String] {
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
