import Foundation
import Testing

@testable import DropApp

/// The update rules from the Updates board, driven through `UpdateModel` the way
/// `UpdateDriver` drives it from Sparkle's events, with Sparkle's replies recorded.
@MainActor
struct UpdateModelTests {
    private let update = AvailableUpdate(
        version: "1.1", size: 4_000_000, notes: ["One", "Two"],
        releaseNotesURL: URL(string: "https://github.com/niduslabs-dev/drop/releases/tag/v1.1"))

    private struct Failure: Error {}

    /// Collects what the model told Sparkle.
    private final class Recorder {
        var replies: [UpdateReply] = []
        var installNowCalls = 0
        var checks = 0
    }

    private func makeModel(automatic: Bool = true) -> (UpdateModel, Recorder) {
        let model = UpdateModel(currentVersion: "1.0", automatic: automatic, isEnabled: true)
        let recorder = Recorder()
        model.requestCheck = { recorder.checks += 1 }
        return (model, recorder)
    }

    // MARK: Ready

    @Test func backgroundDownloadShowsThePopupAndBanner() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        #expect(model.phase == .ready(update))
        #expect(model.wantsPopup)
        #expect(model.isReady)
        #expect(model.popupTitle == "Drop 1.1 is ready")
        #expect(model.sizeDetail == "4 MB, downloaded")
    }

    @Test func restartInstallsThroughSparklesHandler() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        model.perform(.restart)
        #expect(recorder.installNowCalls == 1)
        #expect(model.phase == .installing)
        #expect(!model.wantsPopup)
    }

    @Test func downloadedUpdateFoundIsReadyAndRestartRepliesInstall() {
        let (model, recorder) = makeModel()
        model.found(update, downloaded: true, userInitiated: true) { recorder.replies.append($0) }
        #expect(model.phase == .ready(update))
        #expect(model.wantsPopup)
        model.perform(.restart)
        #expect(recorder.replies == [.install])
        #expect(model.phase == .installing)
    }

    // MARK: Later

    @Test func laterHidesThePopupAndKeepsTheBanner() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        model.perform(.later)
        #expect(!model.wantsPopup)
        #expect(model.isReady, "installs on quit; the Settings banner stays")
        #expect(recorder.installNowCalls == 0)
    }

    @Test func laterAnswersAWaitingPromptWithDismiss() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download)
        model.readyToInstall { recorder.replies.append($0) }
        model.perform(.later)
        #expect(recorder.replies == [.install, .dismiss])
        #expect(model.isReady)
        // Sparkle ends the cycle after the dismiss; the update still installs on quit.
        model.cycleEnded()
        #expect(model.isReady)
    }

    @Test func restartAfterLaterAsksSparkleAgainAndInstalls() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download)
        model.readyToInstall { recorder.replies.append($0) }
        model.perform(.later)
        model.cycleEnded()
        // The banner's Restart to Update: nothing to answer, so a check brings the armed
        // update back as a prompt, answered with install.
        model.perform(.restart)
        #expect(recorder.checks == 1)
        model.found(update, downloaded: true, userInitiated: true) { recorder.replies.append($0) }
        #expect(recorder.replies == [.install, .dismiss, .install])
        #expect(model.phase == .installing)
        #expect(!model.wantsPopup)
    }

    // MARK: Automatic installs off

    @Test func automaticOffAsksBeforeDownloading() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        #expect(model.phase == .available(update))
        #expect(model.wantsPopup)
        #expect(model.popupTitle == "Drop 1.1 is available")
        #expect(model.sizeDetail == "4 MB")
        #expect(recorder.replies.isEmpty, "nothing downloads until Download")
        model.perform(.download)
        #expect(recorder.replies == [.install])
        #expect(model.phase == .downloading(update))
        #expect(!model.wantsPopup)
        model.readyToInstall { recorder.replies.append($0) }
        #expect(model.phase == .ready(update))
        #expect(model.wantsPopup)
    }

    @Test func automaticOnDownloadsAUserCheckStraightAway() {
        let (model, recorder) = makeModel(automatic: true)
        model.checkStarted()
        #expect(model.phase == .checking)
        model.found(update, downloaded: false, userInitiated: true) { recorder.replies.append($0) }
        #expect(recorder.replies == [.install])
        #expect(model.phase == .downloading(update))
        #expect(!model.wantsPopup)
    }

    @Test func switchChangesReachSparkle() {
        let (model, _) = makeModel(automatic: true)
        var sent: [Bool] = []
        model.automaticChanged = { sent.append($0) }
        model.automatic = false
        model.automatic = false
        model.automatic = true
        #expect(sent == [false, true])
    }

    // MARK: Failures

    @Test func failureIsSilent() {
        let (model, recorder) = makeModel()
        let checked = Date(timeIntervalSince1970: 1_000)
        model.lastChecked = checked
        model.checkStarted()
        model.failed(Failure())
        #expect(model.phase == .idle)
        #expect(!model.wantsPopup)
        #expect(model.lastChecked == checked, "a failed check isn't a check")
        #expect(recorder.replies.isEmpty)
    }

    @Test func failureMidDownloadDropsIt() {
        let (model, recorder) = makeModel(automatic: false)
        model.found(update, downloaded: false, userInitiated: false) { recorder.replies.append($0) }
        model.perform(.download)
        model.failed(Failure())
        #expect(model.phase == .idle)
        #expect(!model.wantsPopup)
    }

    @Test func failureKeepsAReadyUpdate() {
        let (model, recorder) = makeModel()
        model.readyOnQuit(update) { recorder.installNowCalls += 1 }
        model.perform(.later)
        model.failed(Failure())
        #expect(model.isReady)
        #expect(!model.wantsPopup)
    }

    @Test func checkFindingNothingGoesBackToIdle() {
        let (model, _) = makeModel()
        model.checkStarted()
        model.notFound()
        #expect(model.phase == .idle)
    }

    @Test func checkIsIgnoredWithoutAnUpdater() {
        let model = UpdateModel(currentVersion: "1.0")
        var checks = 0
        model.requestCheck = { checks += 1 }
        model.perform(.check)
        #expect(checks == 0)
    }

    // MARK: Copy

    /// The time part follows the Mac's clock setting (12 or 24 hours), which overrides the
    /// locale, so the expected time is formatted the same way rather than written out.
    @Test func versionCaptions() throws {
        let (model, _) = makeModel()
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        calendar.locale = locale
        func time(_ date: Date) -> String {
            date.formatted(
                Date.FormatStyle(
                    date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        func caption() -> String { model.versionCaption(now: now, locale: locale, calendar: calendar) }
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 15)))
        #expect(caption() == "Not checked yet")
        let morning = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 12)))
        model.lastChecked = morning
        #expect(caption() == "Up to date \u{00B7} checked today at \(time(morning))")
        model.readyOnQuit(update) {}
        #expect(caption() == "1.1 downloaded \u{00B7} checked today at \(time(morning))")
        let evening = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 18, minute: 40)))
        model.lastChecked = evening
        #expect(caption() == "1.1 downloaded \u{00B7} checked yesterday at \(time(evening))")
        model.lastChecked = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 8))
        #expect(caption() == "1.1 downloaded \u{00B7} checked on 12 Nov")
    }

    @Test func captionWithoutAnUpdater() {
        let model = UpdateModel(currentVersion: "1.0")
        #expect(model.versionCaption() == "Updates are off in test builds.")
    }

    // MARK: Release notes

    @Test func releaseNotesFromAList() {
        let html = """
            <h2>Drop 1.1</h2>
            <ul>
              <li>Faster popups for <b>big</b> disk images</li>
              <li>Install to remembers your choice</li>
              <li>Fixes for licence screens &amp; passwords</li>
              <li>A fourth line nobody sees</li>
            </ul>
            """
        #expect(
            ReleaseNotes.lines(from: html) == [
                "Faster popups for big disk images", "Install to remembers your choice",
                "Fixes for licence screens & passwords",
            ])
    }

    @Test func releaseNotesFromPlainLines() {
        let text = "- First change\n\n* Second change<br>Third change\nFourth"
        #expect(ReleaseNotes.lines(from: text) == ["First change", "Second change", "Third change"])
        #expect(ReleaseNotes.lines(from: nil).isEmpty)
        #expect(ReleaseNotes.lines(from: "").isEmpty)
    }
}
