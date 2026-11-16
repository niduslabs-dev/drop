import Foundation
import Testing

@testable import DropApp

/// "Open the app when it's installed": which plan an install gets, and what each plan
/// does to the surface and the app, with a recorded surface and opener.
@MainActor
struct AfterInstallTests {
    /// Everything the flow asked of its surface and opener, in order.
    @MainActor
    final class Recorder {
        var events: [String] = []
        var opens = true
        var hides = true
        private var opened: CheckedContinuation<Void, Never>?

        var flow: AfterInstall {
            AfterInstall(
                hold: { self.events.append("hold") },
                hideSurface: {
                    self.events.append("hide")
                    return self.hides
                },
                restoreSurface: { self.events.append("restore") },
                open: { app in
                    self.events.append("open \(app.lastPathComponent)")
                    self.opened?.resume()
                    self.opened = nil
                    return self.opens
                })
        }

        /// Returns once the opener has been called, for the plan that doesn't wait for it.
        func waitForOpen() async {
            guard !events.contains(where: { $0.hasPrefix("open") }) else { return }
            await withCheckedContinuation { opened = $0 }
        }
    }

    private let app = URL(filePath: "/Applications/Linea.app")

    @Test func planFollowsTheSettingAndWhetherTheAppWasRunning() {
        #expect(AfterInstallPlan(openAfterInstall: false, wasRunning: false) == .stay)
        #expect(AfterInstallPlan(openAfterInstall: false, wasRunning: true) == .openInPlace)
        #expect(AfterInstallPlan(openAfterInstall: true, wasRunning: false) == .closeThenOpen)
        #expect(AfterInstallPlan(openAfterInstall: true, wasRunning: true) == .closeThenOpen)
    }

    @Test func settingOffLeavesInstalledUpAndOpensNothing() async {
        let recorder = Recorder()
        #expect(await recorder.flow.run(.stay, app: app) == .showsInstalled)
        await Task.yield()
        #expect(recorder.events.isEmpty)
    }

    @Test func settingOnHoldsThenClosesThenOpens() async {
        let recorder = Recorder()
        #expect(await recorder.flow.run(.closeThenOpen, app: app) == .closed)
        #expect(recorder.events == ["hold", "hide", "open Linea.app"])
    }

    @Test func aFailedOpenBringsInstalledBack() async {
        let recorder = Recorder()
        recorder.opens = false
        #expect(await recorder.flow.run(.closeThenOpen, app: app) == .showsInstalled)
        #expect(recorder.events == ["hold", "hide", "open Linea.app", "restore"])
    }

    @Test func aPanelTheUserAlreadyActedOnIsLeftAloneAndNothingOpens() async {
        let recorder = Recorder()
        recorder.hides = false
        #expect(await recorder.flow.run(.closeThenOpen, app: app) == .superseded)
        #expect(recorder.events == ["hold", "hide"])
    }

    @Test func anUpdateWithTheSettingOffReopensTheAppAndKeepsInstalledUp() async {
        let recorder = Recorder()
        let plan = AfterInstallPlan(openAfterInstall: false, wasRunning: true)
        #expect(await recorder.flow.run(plan, app: app) == .showsInstalled)
        await recorder.waitForOpen()
        #expect(recorder.events == ["open Linea.app"])
    }

    @Test func anUpdateWithTheSettingOnClosesBeforeItReopensTheApp() async {
        let recorder = Recorder()
        let plan = AfterInstallPlan(openAfterInstall: true, wasRunning: true)
        #expect(await recorder.flow.run(plan, app: app) == .closed)
        #expect(recorder.events == ["hold", "hide", "open Linea.app"])
    }

    @Test func theInstalledHoldIsLongEnoughForTheTickToDraw() {
        #expect(Theme.Motion.installedHold >= .milliseconds(750))
        #expect(Theme.Motion.installedHold <= .seconds(1))
    }
}
