import AppKit
import DiskImage
import Installer
import SwiftUI
import Verifier

/// The panel's root: picks the board for the model's state. The same view fills the popup
/// and the centred window (`PanelPresentation`).
struct PanelView: View {
    @Bindable var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The boards that are different views. Within one, the board's own views animate
    /// their changes in place; from one to another (licence to ready, password to ready,
    /// warning to installing) the two cross-fade, top edges together.
    private enum Kind: Hashable {
        case install, update, warning, refused, fallback, licence, password, selfImage, hidden
    }

    private var kind: Kind {
        switch model.board {
        case .main, .update, .installing, .done: model.isUpdate ? .update : .install
        case .warning: .warning
        case .refused: .refused
        case .fallback: .fallback
        case .licence: .licence
        case .password: .password
        case .selfImage: .selfImage
        case .hidden: .hidden
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch kind {
                case .install: MainBoard(model: model)
                case .update: UpdateBoard(model: model)
                case .warning: WarningBoard(model: model)
                case .refused: RefusedBoard(model: model)
                case .fallback: FallbackBoard(model: model)
                case .licence: LicenceBoard(model: model)
                case .password: PasswordBoard(model: model)
                case .selfImage: SelfImageBoard(model: model)
                case .hidden: EmptyView()
                }
            }
            .id(kind)
            .transition(.opacity)
        }
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.swap, value: kind)
        .disabled(model.isBusy)
        .onHover { model.isHovered = $0 }
    }
}

/// The install flow's bottom row, for the Main and Update boards: the link, the secondary
/// and the primary capsule, each one view from ready to done (`PanelButtons`), so labels
/// swap, the fill grows and widths change in place.
struct FlowButtonRow: View {
    let model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let buttons = model.buttons
        ButtonRow {
            ZStack(alignment: .leading) {
                switch buttons.link {
                case .openImage(let isEnabled):
                    Button("Open disk image") { model.send(.openImage) }.buttonStyle(.nidusLink())
                        .disabled(!isEnabled)
                        .transition(.opacity)
                case .undoTrash(let isVisible):
                    Button("Undo") { model.send(.undoTrash) }.buttonStyle(.nidusLink())
                        .opacity(isVisible ? 1 : 0)
                        .disabled(!isVisible)
                        .accessibilityHidden(!isVisible)
                        .transition(.opacity)
                }
            }
        } trailing: {
            Button {
                model.send(buttons.secondary.action)
            } label: {
                SwapLabel(title: buttons.secondary.title)
            }
            .buttonStyle(.nidusSecondary)
            .disabled(!buttons.secondary.isEnabled)
            StepCapsule(step: buttons.primary) { model.send($0) }
        }
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.popup, value: layoutKey(buttons))
    }

    /// Everything that changes the row's layout: labels and which link shows.
    private func layoutKey(_ buttons: PanelButtons) -> String {
        "\(buttons.secondary.title)|\(buttons.primary.sizingLabel)|\(buttons.link)"
    }
}

/// The version and size line, with the numbers rolling as they change.
struct VersionLine: View {
    let summary: AppSummary?

    var body: some View {
        RollingNumber(text)
    }

    private var text: String {
        Format.versionAndSize(version: summary?.version, size: summary?.size)
    }
}

// MARK: - 1 · New disk image found, installing, installed

/// Boards 1 to 3 as one view (Progress board): Install fills as the progress and becomes
/// Open, Not now becomes Cancel and then Show in Finder, the status line under the name
/// blur-swaps, and the tick lands on the icon. The popup keeps its width throughout; the
/// Install capsule widens smoothly to fit its label.
struct MainBoard: View {
    @Bindable var model: PanelModel

    private var working: Bool { model.board == .installing }
    private var done: Bool { model.board == .done }

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: model.appName) {
                StatusSwap(key: statusPhase) {
                    RollingNumber(status)
                }
            } badge: {
                if done {
                    DrawnCheck(lineWidth: Theme.Icon.badgeStroke)
                        .padding(Theme.Icon.badgeBorder)
                        .background(Circle().fill(Theme.Colour.surface))
                        .frame(width: Theme.Icon.badge, height: Theme.Icon.badge)
                        .offset(x: Theme.Icon.badgeOffset, y: Theme.Icon.badgeOffset)
                }
            }
            SignerCard(model: model)
            VStack(alignment: .leading, spacing: Theme.Settings.rowSpacing) {
                HStack(spacing: Theme.Card.calloutSpacing) {
                    Text("Install to").foregroundStyle(Theme.Colour.bodyText).dimsWhenDisabled()
                    Spacer()
                    NidusSelect(
                        label: "Install to", selection: model.location, options: InstallLocation.selectOptions
                    ) { model.send(.changeLocation($0)) }
                }
                Toggle("Move the disk image to the Trash", isOn: $model.trashImage)
                    .toggleStyle(.nidusSwitch)
            }
            .font(Theme.Font.body)
            .disabled(!model.buttons.controlsEnabled)
            FlowButtonRow(model: model)
                .padding(.top, Theme.Panel.buttonRowTopPadding)
        }
    }

    /// What the status line is saying. A new phase blur-swaps the line; within a phase the
    /// numbers roll (the size arriving after the version, the bytes copied).
    private var statusPhase: Int {
        if done { return 3 }
        if working { return model.progress.map { $0.fraction < 1 } == true ? 2 : 1 }
        return model.summary == nil ? 0 : 4
    }

    /// The line under the name: reading, version and size, what's being done, the result.
    private var status: String {
        if done {
            let version = model.summary?.version.map { "Version \($0) in " } ?? "In "
            return version + model.destinationName
        }
        if working {
            guard let progress = model.progress, progress.fraction < 1 else { return "Checking the signature" }
            return "Copying files \u{00B7} \(Format.progress(progress))"
        }
        guard let summary = model.summary else { return "Reading\u{2026}" }
        return Format.versionAndSize(version: summary.version, size: summary.size)
    }
}

/// "Signed by … / Notarized by Apple", or the check still running; the two swap with the
/// status blur when the check finishes.
struct SignerCard: View {
    let model: PanelModel

    var body: some View {
        InfoCard {
            // While checking, the card keeps the height of the usual result (signed and
            // notarized), so the panel doesn't grow when it lands.
            ZStack(alignment: .topLeading) {
                if model.isChecking { reservedRows.hidden().accessibilityHidden(true) }
                checkSwap
            }
        }
    }

    private var reservedRows: some View {
        VStack(alignment: .leading, spacing: Theme.Card.rowSpacing) {
            CardRow(symbol: "checkmark.shield", colour: Theme.Colour.good, text: Text("Signed by"))
            CardRow(symbol: "checkmark.circle", colour: Theme.Colour.good, text: Text("Notarized by Apple"))
        }
    }

    private var checkSwap: some View {
        Group {
            StatusSwap(key: model.isChecking) {
                if model.isChecking {
                    WaitingRow(text: waitingText)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Card.rowSpacing) {
                        if let signer = model.summary?.signer {
                            CardRow(
                                symbol: "checkmark.shield", colour: Theme.Colour.good,
                                text: Text("Signed by ") + Text(signer).fontWeight(.semibold))
                        }
                        if model.summary?.isNotarized == true {
                            CardRow(
                                symbol: "checkmark.circle", colour: Theme.Colour.good, text: Text("Notarized by Apple"))
                        }
                    }
                }
            }
        }
    }

    private var waitingText: String {
        switch model.state {
        case .waitingToPrepare: "Drop checks the signature when you click Install."
        case .reading: "Reading the disk image\u{2026}"
        default: "Checking the signature\u{2026}"
        }
    }
}

/// A small spinner and a grey line, while something is still being checked.
struct WaitingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Card.iconSpacing) {
            ProgressView().controlSize(.mini).frame(width: Theme.Card.rowIcon, height: Theme.Card.rowIcon)
            StatusSwap(key: text) { Text(text).foregroundStyle(Theme.Colour.secondaryText) }
        }
    }
}

// MARK: - Already installed (update)

/// The update of an installed copy, from the prompt to done on one board: Quit and Update
/// is one press, and the primary capsule then shows each step ("Quitting …", "Updating …
/// N%", "Open …") while the tick lands on the icon. Nothing else on the board moves.
struct UpdateBoard: View {
    @Bindable var model: PanelModel

    /// The note about the running copy stays from the prompt to done, so the board keeps
    /// its height when the app has quit.
    private var showsRunningNote: Bool {
        model.appIsRunning || model.isQuitting || model.quitFailed || model.reopenAfterInstall
    }

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(
                icon: model.icon, title: "Update \(model.appName)", subtitleSpacing: Theme.Panel.updateTitleSpacing
            ) {
                HStack(spacing: Theme.Header.spacing) {
                    Text(model.summary?.update?.installedVersion ?? "Installed")
                    Image(systemName: "arrow.right").font(.system(size: Theme.Header.icon, weight: .semibold))
                        .accessibilityLabel("to")
                    Text(model.summary?.version ?? "New").fontWeight(.semibold).foregroundStyle(Theme.Colour.bodyText)
                }
                .monospacedDigit()
            } badge: {
                if model.board == .done {
                    DrawnCheck(lineWidth: Theme.Icon.badgeStroke)
                        .padding(Theme.Icon.badgeBorder)
                        .background(Circle().fill(Theme.Colour.surface))
                        .frame(width: Theme.Icon.badge, height: Theme.Icon.badge)
                        .offset(x: Theme.Icon.badgeOffset, y: Theme.Icon.badgeOffset)
                }
            }
            InfoCard {
                developerRow
                CardRow(symbol: "trash", text: Text("The old version goes to the Trash."))
            }
            if showsRunningNote {
                // Updated is good news: the moss info callout. The steps before stay amber.
                let updated = model.board == .done
                Callout(
                    kind: updated ? .info : .warn, symbol: updated ? "info.circle" : "exclamationmark.circle",
                    message: runningNote, reserving: runningNotes)
            }
            FlowButtonRow(model: model)
        }
    }

    /// The running-app note for the step on show. Each step says only what is true then:
    /// open (and quitting) before the swap, quit while it runs, updated at done.
    private var runningNote: String {
        if model.board == .done { return updatedNote }
        if model.quitFailed { return didNotQuitNote }
        if model.reopenAfterInstall { return hasQuitNote }
        return openNote
    }

    /// Every note `runningNote` can show, so the callout keeps the height of the tallest.
    private var runningNotes: [String] { [openNote, didNotQuitNote, hasQuitNote, updatedNote] }

    private var openNote: String { "\(model.appName) is open. Drop quits it first, then opens the new version." }
    private var didNotQuitNote: String { "\(model.appName) didn't quit. Quit it yourself, then try again." }
    private var hasQuitNote: String { "\(model.appName) has quit. Drop opens the new version once it's in place." }
    private var updatedNote: String { "\(model.appName) is updated." }

    @ViewBuilder private var developerRow: some View {
        StatusSwap(key: model.summary?.update?.developer == nil) {
            switch model.summary?.update?.developer {
            case .same:
                CardRow(
                    symbol: "checkmark.shield", colour: Theme.Colour.good,
                    text: Text("Same developer as the installed copy"))
            case .different, .newUnsigned:
                CardRow(
                    symbol: "exclamationmark.shield", colour: Theme.Colour.warning,
                    text: Text("A different developer signed this version."))
            case .installedUnsigned:
                CardRow(symbol: "shield", text: Text("The installed copy isn't signed, so Drop can't compare."))
            case nil:
                WaitingRow(text: "Checking the signature\u{2026}")
            }
        }
    }
}

// MARK: - Drop's own disk image

/// SelfInstall board: the image holds Drop. A newer one points to Check for Updates; the
/// same or an older one has nothing to install. Never Install or Quit and Update.
struct SelfImageBoard: View {
    let model: PanelModel

    var body: some View {
        if let offer = model.selfImage {
            PanelCard {
                ImageHeader(model: model)
                TitleRow(icon: model.icon, title: offer.title) {
                    Text(offer.subtitle).monospacedDigit()
                }
                Callout(kind: .info, symbol: "info.circle", message: offer.message)
                ButtonRow {
                    Button("Open disk image") { model.send(.openImage) }.buttonStyle(.nidusLink())
                } trailing: {
                    if let secondary = offer.secondary {
                        Button(secondary.title) { model.send(secondary.action) }.buttonStyle(.nidusSecondary)
                    }
                    Button(offer.primary.title) { model.send(offer.primary.action) }.buttonStyle(.nidusPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Not notarized

struct WarningBoard: View {
    let model: PanelModel

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: model.appName) {
                VersionLine(summary: model.summary)
            }
            Callout(title: "Apple hasn't checked this app.", message: message)
            ButtonRow {
                Button("Install Anyway") { model.send(.installAnyway) }
                    .buttonStyle(.nidusLink(Theme.Colour.warning))
            } trailing: {
                Button("Show in Finder") { model.send(.showImageInFinder) }.buttonStyle(.nidusSecondary)
                Button("Don't Install") { model.send(.notNow) }.buttonStyle(.nidusPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    var message: String {
        guard case .warning(_, let warning) = model.state else { return "" }
        switch warning {
        case .notNotarized:
            return
                "It's signed by an unknown developer and not notarized. macOS will block it on first open. You can allow it in Privacy & Security."
        case .unsigned:
            return
                "It isn't signed and not notarized. macOS will block it on first open. You can allow it in Privacy & Security."
        case .notarizationUnknown:
            return "Drop couldn't reach Apple to check it. macOS checks it again on first open."
        }
    }
}

// MARK: - Damaged (hard stop)

struct RefusedBoard: View {
    let model: PanelModel

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: model.appName) {
                Text(model.summary?.version.map { "Version \($0)" } ?? "")
            }
            Callout(kind: .error, symbol: "xmark.circle", title: copy.title, message: copy.message)
            ButtonRow {
                Button("Show in Finder") { model.send(.showImageInFinder) }.buttonStyle(.nidusSecondary)
                Button("Close") { model.send(.close) }.buttonStyle(.nidusPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    var copy: (title: String, message: String) {
        guard case .refused(_, let refusal) = model.state else { return ("", "") }
        switch refusal {
        case .damaged:
            return ("This app is damaged.", "Its signature doesn't match its files, so Drop won't install it.")
        case .revoked:
            return ("Apple has blocked this app.", "Its notarization was revoked, so Drop won't install it.")
        case .notChecked:
            return ("Drop couldn't check this app.", "The signature check didn't finish. Try again later.")
        }
    }
}

// MARK: - Can't install this one

struct FallbackBoard: View {
    let model: PanelModel

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: "Drop can't install this one") {
                Text(copy.subtitle)
            }
            InfoCard {
                Text(copy.detail)
                    .lineSpacing(Theme.Card.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ButtonRow {
                if copy.primary != .openImage {
                    Button("Open disk image") { model.send(.openImage) }.buttonStyle(.nidusLink())
                }
            } trailing: {
                Button("Not now") { model.send(.notNow) }.buttonStyle(.nidusSecondary)
                Button(copy.primaryTitle) { model.send(copy.primary) }.buttonStyle(.nidusPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    struct Copy {
        var subtitle: String
        var detail: String
        var primaryTitle: String
        var primary: PanelAction
    }

    var copy: Copy {
        let openImage = (title: "Open disk image", action: PanelAction.openImage)
        switch model.state {
        case .cannotInstall(.packageOnly):
            return Copy(
                subtitle: "This disk image has an installer package.",
                detail: "Apple's Installer runs it instead. It may ask for your password.",
                primaryTitle: "Open Installer", primary: .openInstaller)
        case .cannotInstall(.nameCollision), .failed(.extractor(.nameCollision)):
            return Copy(
                subtitle: "This app needs a case-sensitive disk.",
                detail: "Two of its files have names that differ only by case. A normal Mac disk can't hold both.",
                primaryTitle: "Show in Finder", primary: .showImageInFinder)
        case .cannotInstall(.multipleApps(let names)):
            return Copy(
                subtitle: "This disk image has more than one app.",
                detail: "It has \(names.joined(separator: ", ")). Open it to pick one.",
                primaryTitle: openImage.title, primary: openImage.action)
        case .cannotInstall(.noApp):
            return Copy(
                subtitle: "There's no app in this disk image.",
                detail: "Open it to see what's inside.", primaryTitle: openImage.title, primary: openImage.action)
        case .cannotInstall(.licenceNotShown):
            return Copy(
                subtitle: "Drop can't show its licence agreement.",
                detail: "Open it in Finder, which shows the licence first.",
                primaryTitle: openImage.title, primary: openImage.action)
        case .cannotInstall(.wontAttach), .cannotInstall(.unreadable):
            return Copy(
                subtitle: "Drop can't read this disk image.",
                detail: "It may still be downloading or be damaged. Finder may be able to open it.",
                primaryTitle: openImage.title, primary: openImage.action)
        case .failed(.extractor(.destinationNotWritable)):
            return Copy(
                subtitle: "Drop can't write to \(model.destinationName).",
                detail: "Pick another place to install to, or open the disk image and drag the app yourself.",
                primaryTitle: openImage.title, primary: openImage.action)
        default:
            return Copy(
                subtitle: "Something went wrong while installing.",
                detail: "Nothing was changed. Open the disk image to install the app yourself.",
                primaryTitle: openImage.title, primary: openImage.action)
        }
    }
}

// MARK: - Licence agreement

struct LicenceBoard: View {
    @Bindable var model: PanelModel

    var body: some View {
        PanelCard(spacing: Theme.Panel.licenceSpacing) {
            // The same header as every other board, the same gap below it.
            ImageHeader(model: model)
                .padding(.bottom, Theme.Panel.spacing - Theme.Panel.licenceSpacing)
            HStack(spacing: Theme.Icon.titleSpacing) {
                AppIconView(
                    icon: model.icon, size: Theme.Icon.licenceSize, cornerRadius: Theme.Icon.licenceCornerRadius,
                    glyph: Theme.Icon.licenceGlyph)
                VStack(alignment: .leading, spacing: Theme.Panel.titleSpacing) {
                    Text("\(model.appName)'s licence agreement").font(Theme.Font.licenceTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Agree to it to install \(model.appName).").font(Theme.Font.subtitle)
                        .foregroundStyle(Theme.Colour.secondaryText)
                }
                Spacer(minLength: 0)
                if let licence, licence.languages.count > 1 {
                    NidusSelect(
                        label: "Language", selection: model.licenceLanguage,
                        options: LicenceText.languageOptions(licence)
                    ) { model.licenceLanguage = $0 }
                }
            }
            LicenceTextView(text: attributedText)
                .frame(height: Theme.Licence.textHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Licence.textCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Licence.textCornerRadius, style: .continuous)
                        .strokeBorder(Theme.Colour.hairline)
                }
                .accessibilityLabel("Licence text")
            ButtonRow {
                Button("Save as PDF\u{2026}") { model.send(.saveLicence) }.buttonStyle(.nidusLink())
            } trailing: {
                Button("Disagree") { model.send(.disagreeLicence) }.buttonStyle(.nidusSecondary)
                Button("Agree and Install") { model.send(.agreeLicence) }.buttonStyle(.nidusPrimary)
                    .keyboardShortcut(.defaultAction)
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

/// A scrolling, read-only text view, so RTF licences keep their formatting.
struct LicenceTextView: NSViewRepresentable {
    let text: NSAttributedString
    /// The popup draws the text background; the install window's card shows through.
    var drawsBackground = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = drawsBackground
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = drawsBackground
            textView.backgroundColor = .textBackgroundColor
            textView.usesAdaptiveColorMappingForDarkAppearance = true
            textView.textContainerInset = NSSize(
                width: Theme.Licence.textPadding / 2, height: Theme.Licence.textPadding)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.attributedString() != text else { return }
        textView.textStorage?.setAttributedString(text)
        textView.scrollToBeginningOfDocument(nil)
    }
}

enum LicenceText {
    /// Classic Mac OS region codes to languages, for the picker and to start on the
    /// system language. Only the regions licences use in practice.
    static let regionLanguages: [UInt16: String] = [
        0: "en", 1: "fr", 2: "en", 3: "de", 4: "it", 5: "nl", 6: "nl", 7: "sv", 8: "es", 9: "da", 10: "pt",
        11: "fr", 12: "nb", 13: "he", 14: "ja", 15: "en", 16: "ar", 17: "fi", 18: "fr", 19: "de", 20: "el",
        21: "is", 24: "tr", 33: "ko", 51: "ko", 52: "zh-Hans", 53: "zh-Hant",
    ]

    /// The Language select's choices: each language by its own name.
    static func languageOptions(_ licence: LicenceAgreement) -> [SelectOption<Int>] {
        licence.languages.indices.map { index in
            let name = languageName(licence.languages[index], index: index)
            return SelectOption(value: index, label: name, accessibilityLabel: name)
        }
    }

    static func languageName(_ language: LicenceAgreement.Language, index: Int) -> String {
        if let name = language.buttons.first, !name.isEmpty { return name }
        if let code = regionLanguages[language.regionCode],
            let name = Locale.current.localizedString(forIdentifier: code)
        {
            return name.capitalizedFirst
        }
        return "Language \(index + 1)"
    }

    /// The language to show first: the system's, when the licence has it, else the
    /// licence's own default.
    static func initialLanguage(_ licence: LicenceAgreement) -> Int {
        let preferred = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier }
        if let preferred,
            let index = licence.languages.firstIndex(where: {
                regionLanguages[$0.regionCode].map { Locale(identifier: $0).language.languageCode?.identifier }
                    == preferred
            })
        {
            return index
        }
        return licence.languages.indices.contains(licence.defaultLanguageIndex) ? licence.defaultLanguageIndex : 0
    }

    static func attributed(_ language: LicenceAgreement.Language) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1), .foregroundColor: NSColor.labelColor,
        ]
        switch language.body {
        case .rtf(let bytes):
            if let rtf = NSAttributedString(rtf: Data(bytes), documentAttributes: nil) { return rtf }
            return NSAttributedString(string: "", attributes: attributes)
        case .plain(_, let text):
            return NSAttributedString(string: text, attributes: attributes)
        case .missing:
            return NSAttributedString(string: "This language has no text.", attributes: attributes)
        }
    }
}

// MARK: - Encrypted disk image

struct PasswordBoard: View {
    @Bindable var model: PanelModel
    @FocusState private var focused: Bool

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: "This disk image is locked") {
                Text("Enter its password to see what's inside.")
            }
            VStack(alignment: .leading, spacing: Theme.Password.spacing) {
                Text("Password").font(Theme.Font.small).foregroundStyle(Theme.Colour.bodyText)
                SecureField("Password", text: $model.password)
                    .labelsHidden()
                    .focused($focused)
                    .nidusField(isFocused: focused, isError: wrongPassword)
                    .onSubmit { model.send(.submitPassword) }
                if wrongPassword {
                    Text("That password didn't work. Try again.")
                        .font(Theme.Font.small).foregroundStyle(Theme.Colour.error)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            Text("Drop uses it once to open the image and doesn't save it.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Colour.secondaryText)
            ButtonRow {
                Button("Not now") { model.send(.notNow) }.buttonStyle(.nidusSecondary)
                Button("Open") { model.send(.submitPassword) }.buttonStyle(.nidusPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.password.isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private var wrongPassword: Bool {
        if case .needsPassword(let attempt) = model.state { return attempt > 1 }
        return false
    }
}
