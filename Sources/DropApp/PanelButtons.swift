import Foundation

/// What the buttons of the install flow show in each state, for the popup and the install
/// window alike: ready, Quit and Update waiting for the app to go, working, done. A pure
/// value, so the sequence is tested without a view (`PanelButtonsTests`), and one source,
/// so both surfaces keep one primary and one secondary view whose labels change in place
/// and animate, instead of a different button per state.
struct PanelButtons: Equatable {
    /// The primary capsule's states, drawn by one `StepCapsule`.
    enum Primary: Equatable {
        /// A solid button that sends `action`: Install, Update, Quit and Update.
        case action(title: String, PanelAction)
        /// "Quitting Linea…": Drop asked the running copy to quit and waits. No amount is
        /// known, so the capsule shimmers instead of filling.
        case quitting(app: String)
        /// "Installing… 62%" or "Updating… 62%": the capsule fills.
        case progress(verb: String, fraction: Double)
        /// Solid, with nothing to press: so little is left that a fill would only flash
        /// (`PanelModel.skipsProgress`), and the next thing shown is `open`.
        case busy(title: String)
        /// "Open Linea", once installed.
        case open(app: String)
    }

    struct Secondary: Equatable {
        var title: String
        var action: PanelAction
        /// False while Cancel is no longer safe: the copy is being swapped into place.
        var isEnabled = true
    }

    /// The link slot: Open disk image, or Undo for the trashed image once installed.
    enum Link: Equatable {
        case openImage(isEnabled: Bool)
        case undoTrash(isVisible: Bool)
    }

    var primary: Primary
    var secondary: Secondary
    var link: Link
    /// Install to and the Trash switch can still change something. False from the click
    /// on: they dim in place.
    var controlsEnabled: Bool

    /// - Parameters:
    ///   - board: `main`, `update`, `installing` or `done`; the other boards have their
    ///     own buttons and get the ready set.
    ///   - progress: the staging fraction while there is one.
    init(
        board: Board, appName: String, isUpdate: Bool, appIsRunning: Bool, isQuitting: Bool, progress: Double?,
        skipsProgress: Bool, canUndoTrash: Bool
    ) {
        let verb = isUpdate ? "Updating" : "Installing"
        switch board {
        case .done:
            primary = .open(app: appName)
            secondary = Secondary(title: "Show in Finder", action: .showAppInFinder)
            link = .undoTrash(isVisible: canUndoTrash)
            controlsEnabled = false
        case .installing:
            // Still copying: cancelling only deletes the staged copy. With nothing left to
            // copy the installed app is being replaced, and that must run to its end.
            let copying = progress.map { $0 < 1 } ?? false
            if skipsProgress {
                primary = .busy(title: isUpdate ? "Updating\u{2026}" : "Install")
            } else {
                primary = .progress(verb: verb, fraction: min(progress ?? 0, Theme.Motion.progressCeiling))
            }
            secondary = Secondary(title: "Cancel", action: .cancelInstall, isEnabled: copying)
            link = .openImage(isEnabled: false)
            controlsEnabled = false
        default:
            if isQuitting {
                primary = .quitting(app: appName)
                secondary = Secondary(title: "Cancel", action: .cancelInstall)
                link = .openImage(isEnabled: false)
                controlsEnabled = false
            } else {
                let title = isUpdate ? (appIsRunning ? "Quit and Update" : "Update") : "Install"
                primary = .action(title: title, .install)
                secondary = Secondary(title: "Not now", action: .notNow)
                link = .openImage(isEnabled: true)
                controlsEnabled = true
            }
        }
    }
}

extension PanelButtons.Primary {
    /// The label as shown.
    var label: String {
        switch self {
        case .action(let title, _), .busy(let title): title
        case .quitting(let app): "Quitting \(app)\u{2026}"
        case .progress(let verb, let fraction): "\(verb)\u{2026} \(Self.percent(fraction))%"
        case .open(let app): "Open \(app)"
        }
    }

    /// The label the capsule is sized for: the widest a progress label gets, so the
    /// capsule doesn't twitch as digits come and go.
    var sizingLabel: String {
        if case .progress(let verb, _) = self { return "\(verb)\u{2026} 100%" }
        return label
    }

    /// What pressing the capsule sends, when it can be pressed.
    var action: PanelAction? {
        switch self {
        case .action(_, let action): action
        case .open: .openApp
        case .quitting, .progress, .busy: nil
        }
    }

    /// Drawn as the solid moss button (else as the track with its fill or shimmer).
    var isSolid: Bool {
        switch self {
        case .action, .busy, .open: true
        case .quitting, .progress: false
        }
    }

    /// How much of the track is filled. Zero before any progress, so the fill grows in
    /// from the left edge; full once done, so it closes under the solid button.
    var fill: Double {
        switch self {
        case .progress(_, let fraction): min(max(fraction, 0), 1)
        case .open: 1
        case .action, .busy, .quitting: 0
        }
    }

    /// The label's words without its number: a change blur-swaps the label, while the
    /// number alone rolls.
    var phrase: String {
        if case .progress(let verb, _) = self { return verb }
        return label
    }

    static func percent(_ fraction: Double) -> Int { Int((min(max(fraction, 0), 1) * 100).rounded()) }
}

extension PanelModel {
    /// Any update of an installed copy: the popup shows the Update board from the prompt
    /// to done.
    var isUpdate: Bool { summary?.update != nil }

    var buttons: PanelButtons {
        PanelButtons(
            board: board, appName: appName, isUpdate: isUpdate, appIsRunning: appIsRunning, isQuitting: isQuitting,
            progress: progress?.fraction, skipsProgress: skipsProgress, canUndoTrash: trashedImage != nil)
    }
}
