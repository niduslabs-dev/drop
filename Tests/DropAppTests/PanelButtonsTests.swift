import Testing

@testable import DropApp

/// The buttons of the install flow, state by state: what the primary capsule shows, what
/// the secondary offers and when the controls are dimmed.
struct PanelButtonsTests {
    private func buttons(
        _ board: Board, isUpdate: Bool = true, appIsRunning: Bool = false, isQuitting: Bool = false,
        progress: Double? = nil, skipsProgress: Bool = false, canUndoTrash: Bool = false
    ) -> PanelButtons {
        PanelButtons(
            board: board, appName: "Linea", isUpdate: isUpdate, appIsRunning: appIsRunning, isQuitting: isQuitting,
            progress: progress, skipsProgress: skipsProgress, canUndoTrash: canUndoTrash)
    }

    @Test func quitAndUpdateRunsFromThePromptToDoneInOnePress() {
        // The prompt.
        let prompt = buttons(.update, appIsRunning: true)
        #expect(prompt.primary == .action(title: "Quit and Update", .install))
        #expect(prompt.secondary == .init(title: "Not now", action: .notNow))
        #expect(prompt.controlsEnabled)

        // Pressed: waiting for the app to quit.
        let quitting = buttons(.update, appIsRunning: true, isQuitting: true)
        #expect(quitting.primary == .quitting(app: "Linea"))
        #expect(quitting.primary.label == "Quitting Linea\u{2026}")
        #expect(quitting.primary.action == nil, "nothing more to press")
        #expect(quitting.secondary == .init(title: "Cancel", action: .cancelInstall, isEnabled: true))
        #expect(!quitting.controlsEnabled)
        #expect(quitting.link == .openImage(isEnabled: false))

        // The app has gone: updating, with the fill.
        let updating = buttons(.installing, progress: 0.62)
        #expect(updating.primary == .progress(verb: "Updating", fraction: 0.62))
        #expect(updating.primary.label == "Updating\u{2026} 62%")
        #expect(updating.secondary.isEnabled, "still copying: Cancel is safe")
        #expect(!updating.controlsEnabled)

        // Done.
        let done = buttons(.done, canUndoTrash: true)
        #expect(done.primary == .open(app: "Linea"))
        #expect(done.primary.action == .openApp)
        #expect(done.secondary == .init(title: "Show in Finder", action: .showAppInFinder))
        #expect(done.link == .undoTrash(isVisible: true))
    }

    @Test func aQuitThatTimesOutPutsThePromptBack() {
        let restored = buttons(.update, appIsRunning: true, isQuitting: false)
        #expect(restored.primary == .action(title: "Quit and Update", .install))
        #expect(restored.secondary.title == "Not now")
        #expect(restored.controlsEnabled)
        #expect(restored.link == .openImage(isEnabled: true))
    }

    @Test func cancelIsOfferedUntilTheSwapAndDisabledDuringIt() {
        #expect(buttons(.update, appIsRunning: true, isQuitting: true).secondary.isEnabled)
        #expect(buttons(.installing, progress: 0.3).secondary.isEnabled)
        #expect(!buttons(.installing, progress: 1).secondary.isEnabled, "nothing left to copy: the swap")
        #expect(!buttons(.installing, progress: nil).secondary.isEnabled)
        #expect(!buttons(.installing, progress: 1, skipsProgress: true).secondary.isEnabled)
    }

    @Test func stagingAlreadyFinishedGoesStraightToDoneWithoutAFill() {
        let update = buttons(.installing, progress: 1, skipsProgress: true)
        #expect(update.primary == .busy(title: "Updating\u{2026}"))
        #expect(update.primary.action == nil)
        #expect(update.primary.isSolid)
        let install = buttons(.installing, isUpdate: false, progress: 1, skipsProgress: true)
        #expect(install.primary == .busy(title: "Install"))
    }

    @Test func aNewInstallReadsInstallAndInstalling() {
        #expect(buttons(.main, isUpdate: false).primary == .action(title: "Install", .install))
        #expect(buttons(.installing, isUpdate: false, progress: 0.3).primary.label == "Installing\u{2026} 30%")
        #expect(buttons(.update).primary == .action(title: "Update", .install))
    }

    @Test func theFillNeverPassesTheCeilingAndStartsFromZero() {
        #expect(buttons(.installing, progress: 1).primary == .progress(verb: "Updating", fraction: 0.9))
        #expect(buttons(.update, isQuitting: true).primary.fill == 0)
        #expect(buttons(.update).primary.fill == 0)
        #expect(buttons(.done).primary.fill == 1)
    }

    @Test func theCapsuleIsSizedForTheWidestProgressLabel() {
        #expect(buttons(.installing, progress: 0.05).primary.sizingLabel == "Updating\u{2026} 100%")
        #expect(buttons(.done).primary.sizingLabel == "Open Linea")
    }
}
