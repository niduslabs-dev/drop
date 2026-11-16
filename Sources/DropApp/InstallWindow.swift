import AppKit
import DiskImage
import Installer
import SwiftUI

/// The AppWindow primitive for an image the user opened (double-click, Open With): a
/// centred column that leads with the app, then one obvious decision (InstallWindow board).
/// Its own layout, not the popup's stretched: the popup is a glanceable notification, this
/// is a moment the user asked for. Driven by the same `PanelModel` and `InstallSession`
/// states as the popup.
///
/// ```
/// media 96 · title 22 · meta 13 · details card · options card · actions (240 × 38 stack)
/// ```
///
/// While installing, the Install capsule itself fills as the progress (Progress board), so
/// nothing in the window moves from ready to done. Return fires the one primary; Esc is the window's
/// cancel (`CentredPanelWindow`), which the controller maps to Not now, Disagree, Cancel or
/// Close per state.
struct InstallWindowView: View {
    @Bindable var model: PanelModel
    @Environment(\.titleBarHeight) private var titleBarHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The window's states, from the model's board.
    enum Phase: Equatable {
        case ready, licence, password, working, done, warning, refused, fallback, selfImage, hidden
    }

    var phase: Phase {
        switch model.board {
        case .main, .update: .ready
        case .licence: .licence
        case .password: .password
        case .installing: .working
        case .done: .done
        case .warning: .warning
        case .refused: .refused
        case .fallback: .fallback
        case .selfImage: .selfImage
        case .hidden: .hidden
        }
    }

    var body: some View {
        if phase == .hidden {
            EmptyView()
        } else {
            column
                .padding(.top, titleBarHeight + Theme.InstallWindow.titleBarGap)
                .padding(.horizontal, Theme.InstallWindow.sideInset)
                .padding(.bottom, Theme.InstallWindow.bottomInset)
                .frame(width: Theme.InstallWindow.width)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Colour.bodyText)
                .environment(\.cardScale, .window)
                .background(SurfaceBackground(kind: .window))
                .disabled(model.isBusy)
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            InstallWindowMedia(model: model, phase: phase)
            Text(model.selfImage?.title ?? model.appName)
                .font(Theme.Font.windowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, Theme.InstallWindow.iconToTitle)
            StatusSwap(key: meta) {
                Text(meta).monospacedDigit().lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
            }
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Colour.secondaryText)
            .padding(.top, Theme.InstallWindow.titleToMeta)
            VStack(spacing: Theme.InstallWindow.detailsToOptions) {
                details.transition(.opacity)
                if hasOptions { options.transition(.opacity) }
            }
            .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.swap, value: detailsKey)
            .padding(.top, Theme.InstallWindow.metaToDetails)
            actionsSlot
                .padding(.top, Theme.InstallWindow.optionsToActions)
        }
    }

    // MARK: Meta

    /// The line under the name: version and size, the update's versions, the result once
    /// installed, or what a fallback or locked image needs. Blur-swaps when it changes.
    private var meta: String {
        switch phase {
        case .done:
            let time = model.installDuration.map { " \u{00B7} " + Self.seconds($0) } ?? ""
            return "Installed in \(model.destinationName)\(time)"
        case .fallback:
            return FallbackBoard(model: model).copy.subtitle
        case .password:
            return "Enter its password to see what's inside."
        case .working:
            guard let progress = model.progress, progress.fraction < 1 else { return "Checking the signature" }
            return "Copying files \u{00B7} \(Format.progress(progress))"
        case .selfImage:
            return model.selfImage?.subtitle ?? ""
        default:
            if model.isQuitting { return "Waiting for \(model.appName) to quit" }
            if model.quitFailed { return "\(model.appName) didn't quit. Quit it yourself, then try again." }
            if let update = model.summary?.update, let version = model.summary?.version {
                return "Updates \(update.installedVersion ?? "the installed copy") to \(version)"
            }
            let version = model.summary?.version ?? model.preview?.version
            let size = model.summary?.size ?? model.preview?.size
            let parts = [version.map { "Version \($0)" }, size.map(Format.size)].compactMap(\.self)
            return parts.isEmpty ? "Reading\u{2026}" : parts.joined(separator: " \u{00B7} ")
        }
    }

    /// "1.2 s": one decimal, in the user's locale.
    static func seconds(_ duration: Duration) -> String {
        duration.seconds.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        switch phase {
        case .ready, .working, .done:
            InstallDetailsCard(model: model)
        case .licence:
            LicenceCard(model: model)
        case .password:
            PasswordSlot(model: model)
        case .warning:
            Callout(title: "Apple hasn't checked this app.", message: WarningBoard(model: model).message)
        case .refused:
            let copy = RefusedBoard(model: model).copy
            Callout(kind: .error, symbol: "xmark.circle", title: copy.title, message: copy.message)
        case .fallback:
            InfoCard {
                Text(FallbackBoard(model: model).copy.detail)
                    .lineSpacing(Theme.Card.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .selfImage:
            Callout(kind: .info, symbol: "info.circle", message: model.selfImage?.message ?? "")
        case .hidden:
            EmptyView()
        }
    }

    /// Which details and options show: ready, working and done share theirs.
    private var detailsKey: String {
        switch phase {
        case .ready, .working, .done: "flow"
        default: "\(phase)"
        }
    }

    // MARK: Options

    private var hasOptions: Bool { [.ready, .working, .done, .warning].contains(phase) }

    /// Install to and the Trash switch. Each row dims in place as one, label and control
    /// (`Theme.Control.disabledOpacity`), once it can no longer change anything: while
    /// installing and after.
    private var options: some View {
        RowCard {
            SettingsRow("Install to") {
                NidusSelect(
                    label: "Install to", selection: model.location, options: InstallLocation.selectOptions
                ) { model.send(.changeLocation($0)) }
            }
            SwitchRow(title: "Move the disk image to the Trash", isOn: $model.trashImage)
        }
        .disabled(!model.buttons.controlsEnabled || phase == .done)
    }

    // MARK: Actions

    /// Ready, working and done share one stack, so the buttons keep their places and sizes:
    /// Install fills as the progress and becomes Open, Not now becomes Cancel and then Show
    /// in Finder, and the link slot keeps its height when it has nothing to offer.
    private var actionsSlot: some View { actions }

    private var actions: some View {
        VStack(spacing: Theme.InstallWindow.actionSpacing) {
            switch phase {
            case .ready, .working, .done:
                flowActions
            case .licence:
                primary("Agree and Install", .agreeLicence)
                secondary("Disagree", .disagreeLicence)
                link("Save as PDF\u{2026}", .saveLicence)
            case .password:
                primary("Open", .submitPassword).disabled(model.password.isEmpty)
                secondary("Not now", .notNow)
            case .warning:
                primary("Don't Install", .notNow)
                secondary("Show in Finder", .showImageInFinder)
                link("Install Anyway", .installAnyway, colour: Theme.Colour.warning)
            case .refused:
                primary("Close", .close)
                secondary("Show in Finder", .showImageInFinder)
            case .fallback:
                let copy = FallbackBoard(model: model).copy
                primary(copy.primaryTitle, copy.primary)
                secondary("Not now", .notNow)
                if copy.primary != .openImage { link("Open disk image", .openImage) }
            case .selfImage:
                if let offer = model.selfImage {
                    primary(offer.primary.title, offer.primary.action)
                    if let other = offer.secondary { secondary(other.title, other.action) }
                    link("Open disk image", .openImage)
                }
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.swap, value: actionsKey)
    }

    /// What the actions slot holds: a change of phase kind cross-fades the buttons, and a
    /// change of the flow's link cross-fades the link.
    private var actionsKey: String {
        switch phase {
        case .ready, .working, .done: "flow \(model.buttons.link)"
        default: "\(phase)"
        }
    }

    /// Ready, working and done as the same three views (`PanelButtons`): the labels swap,
    /// the capsule fills and the link cross-fades in place.
    @ViewBuilder private var flowActions: some View {
        let buttons = model.buttons
        StepCapsule(step: buttons.primary, size: .hero) { model.send($0) }
        Button {
            model.send(buttons.secondary.action)
        } label: {
            SwapLabel(title: buttons.secondary.title, fills: true)
        }
        .buttonStyle(.nidusHeroSecondary)
        .disabled(!buttons.secondary.isEnabled)
        ZStack {
            switch buttons.link {
            case .openImage(let isEnabled):
                link("Open disk image", .openImage).disabled(!isEnabled).transition(.opacity)
            case .undoTrash(let isVisible):
                link("Undo moving the disk image", .undoTrash)
                    .opacity(isVisible ? 1 : 0)
                    .disabled(!isVisible)
                    .accessibilityHidden(!isVisible)
                    .transition(.opacity)
            }
        }
    }

    private func primary(_ title: String, _ action: PanelAction) -> some View {
        Button(title) { model.send(action) }
            .buttonStyle(.nidusHeroPrimary)
            .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: String, _ action: PanelAction) -> some View {
        Button(title) { model.send(action) }.buttonStyle(.nidusHeroSecondary)
    }

    private func link(_ title: String, _ action: PanelAction, colour: Color = Theme.Colour.link) -> some View {
        Button(title) { model.send(action) }.buttonStyle(.nidusLink(colour))
    }
}

/// The 96 pt icon, with the working ring round it and the tick badge that lands on its
/// corner when installed.
private struct InstallWindowMedia: View {
    let model: PanelModel
    let phase: InstallWindowView.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AppIconView(
            icon: model.icon, size: Theme.InstallWindow.icon, cornerRadius: Theme.InstallWindow.iconCornerRadius,
            glyph: Theme.InstallWindow.iconGlyph
        )
        .overlay(alignment: .bottomTrailing) {
            if phase == .done {
                DrawnCheck(lineWidth: Theme.InstallWindow.badgeStroke)
                    .padding(Theme.InstallWindow.badgeBorder)
                    .background(Circle().fill(Theme.Colour.surface))
                    .frame(width: Theme.InstallWindow.badge, height: Theme.InstallWindow.badge)
                    .offset(x: Theme.InstallWindow.badgeOffset, y: Theme.InstallWindow.badgeOffset)
                    .transition(
                        reduceMotion ? .opacity : .scale(scale: Theme.Motion.checkScaleFrom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.checkScale, value: phase)
    }
}

/// Made by, Checked by Apple and From, 24 apart. The first two wait with a spinner while
/// the check runs, and swap in with the status blur when it ends.
private struct InstallDetailsCard: View {
    let model: PanelModel

    var body: some View {
        InfoCard(spacing: 0) {
            row("Made by") {
                if model.isChecking {
                    waiting
                } else if let signer = model.summary?.signer {
                    checked(signer)
                } else {
                    Text("Not signed").foregroundStyle(Theme.Colour.secondaryText)
                }
            }
            row("Checked by Apple") {
                if model.isChecking {
                    waiting
                } else if model.summary?.isNotarized == true {
                    checked("Notarized")
                } else {
                    Text("Not notarized").foregroundStyle(Theme.Colour.secondaryText)
                }
            }
            row("From") {
                Text(model.dmg.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: Theme.Row.labelControlGap) {
            Text(label).foregroundStyle(Theme.Colour.secondaryText)
            Spacer(minLength: 0)
            StatusSwap(key: model.isChecking) { value() }
        }
        .font(Theme.Font.body)
        .frame(height: Theme.InstallWindow.detailRow)
        .accessibilityElement(children: .combine)
    }

    private func checked(_ text: String) -> some View {
        HStack(spacing: Theme.InstallWindow.detailIconGap) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: Theme.InstallWindow.detailIcon, weight: .semibold))
                .foregroundStyle(Theme.Colour.good)
            Text(text).foregroundStyle(Theme.Colour.bodyText).lineLimit(1).truncationMode(.middle)
        }
    }

    private var waiting: some View {
        HStack(spacing: Theme.InstallWindow.detailIconGap) {
            ProgressView().controlSize(.mini)
            Text("Checking\u{2026}").foregroundStyle(Theme.Colour.secondaryText)
        }
    }
}

/// The licence in a 220 pt card that scrolls inside, and the Language select only when
/// the image has several languages.
private struct LicenceCard: View {
    @Bindable var model: PanelModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(spacing: Theme.InstallWindow.detailsToOptions) {
            LicenceTextView(text: attributedText, drawsBackground: false)
                .frame(height: Theme.InstallWindow.licenceHeight)
                .background(Theme.Colour.infoFill, in: shape)
                .clipShape(shape)
                .overlay { shape.strokeBorder(Theme.Colour.hairline, lineWidth: Theme.Radius.cardHairline) }
                .accessibilityLabel("Licence text")
            if let licence, licence.languages.count > 1 {
                HStack {
                    Text("Language").font(Theme.Font.small).foregroundStyle(Theme.Colour.secondaryText)
                    Spacer(minLength: 0)
                    NidusSelect(
                        label: "Language", selection: model.licenceLanguage,
                        options: LicenceText.languageOptions(licence)
                    ) { model.licenceLanguage = $0 }
                }
            }
        }
    }

    private var licence: LicenceAgreement? {
        if case .needsLicence(let licence, _) = model.state { return licence }
        return nil
    }

    private var attributedText: NSAttributedString {
        guard let licence, licence.languages.indices.contains(model.licenceLanguage) else {
            return NSAttributedString()
        }
        return LicenceText.attributed(licence.languages[model.licenceLanguage])
    }
}

/// The locked image's password field, in the details slot.
private struct PasswordSlot: View {
    @Bindable var model: PanelModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Password.spacing) {
            SecureField("Password", text: $model.password)
                .labelsHidden()
                .focused($focused)
                .nidusField(isFocused: focused, isError: wrongPassword)
                .onSubmit { model.send(.submitPassword) }
            Text(
                wrongPassword
                    ? "That password didn't work. Try again." : "Drop uses it once and doesn't save it."
            )
            .font(Theme.Font.small)
            .foregroundStyle(wrongPassword ? Theme.Colour.error : Theme.Colour.secondaryText)
        }
        .onAppear { focused = true }
    }

    private var wrongPassword: Bool {
        if case .needsPassword(let attempt) = model.state { return attempt > 1 }
        return false
    }
}
