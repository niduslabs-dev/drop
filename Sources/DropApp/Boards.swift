import AppKit
import DiskImage
import Installer
import SwiftUI
import Verifier

/// The panel's root: picks the board for the model's state.
struct PanelView: View {
    @Bindable var model: PanelModel

    var body: some View {
        Group {
            switch model.board {
            case .main: MainBoard(model: model)
            case .update: UpdateBoard(model: model)
            case .installing: InstallingBoard(model: model)
            case .done: DoneBoard(model: model)
            case .warning: WarningBoard(model: model)
            case .refused: RefusedBoard(model: model)
            case .fallback: FallbackBoard(model: model)
            case .licence: LicenceBoard(model: model)
            case .password: PasswordBoard(model: model)
            case .hidden: EmptyView()
            }
        }
        .disabled(model.isBusy)
        .onHover { model.isHovered = $0 }
    }
}

// MARK: - 1 · New disk image found

struct MainBoard: View {
    @Bindable var model: PanelModel

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: model.appName) {
                Text(versionLine)
            }
            SignerCard(model: model)
            VStack(alignment: .leading, spacing: Theme.Settings.rowSpacing) {
                HStack(spacing: Theme.Card.calloutSpacing) {
                    Text("Install to").foregroundStyle(Theme.Colour.bodyText)
                    Spacer()
                    Menu {
                        ForEach(InstallLocation.allCases) { location in
                            Button(location.title) { model.send(.changeLocation(location)) }
                        }
                    } label: {
                        Label(model.location.title, systemImage: "folder")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .accessibilityLabel("Install to")
                    .accessibilityValue(model.location.title)
                }
                Toggle("Move the disk image to the Trash", isOn: $model.trashImage)
                    .toggleStyle(.checkbox)
            }
            .font(Theme.Font.body)
            ButtonRow {
                Button("Open disk image") { model.send(.openImage) }.buttonStyle(LinkButtonStyle())
            } trailing: {
                Button("Not now") { model.send(.notNow) }.buttonStyle(SecondaryButtonStyle())
                Button("Install") { model.send(.install) }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 2)
        }
    }

    private var versionLine: String {
        let parts = [model.summary?.version.map { "Version \($0)" }, model.summary.map { Format.size($0.size) }]
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}

/// "Signed by … / Notarized by Apple", or the check still running.
struct SignerCard: View {
    let model: PanelModel

    var body: some View {
        InfoCard {
            if model.isChecking {
                HStack(spacing: Theme.Card.iconSpacing) {
                    ProgressView().controlSize(.mini).frame(width: Theme.Card.rowIcon, height: Theme.Card.rowIcon)
                    Text(waitingText).foregroundStyle(Theme.Colour.secondaryText)
                }
            } else {
                if let signer = model.summary?.signer {
                    CardRow(
                        symbol: "checkmark.shield", colour: Theme.Colour.good,
                        text: Text("Signed by ") + Text(signer).fontWeight(.semibold))
                }
                if model.summary?.isNotarized == true {
                    CardRow(symbol: "checkmark.circle", colour: Theme.Colour.good, text: Text("Notarized by Apple"))
                }
            }
        }
    }

    private var waitingText: String {
        if case .waitingToPrepare = model.state { return "Drop checks the signature when you click Install." }
        return "Checking the signature…"
    }
}

// MARK: - Already installed (update)

struct UpdateBoard: View {
    @Bindable var model: PanelModel

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: "Update \(model.appName)", subtitleSpacing: 4) {
                HStack(spacing: Theme.Header.spacing) {
                    Text(model.summary?.update?.installedVersion ?? "Installed")
                    Image(systemName: "arrow.right").font(.system(size: Theme.Header.icon, weight: .semibold))
                        .accessibilityLabel("to")
                    Text(model.summary?.version ?? "New").fontWeight(.semibold).foregroundStyle(Theme.Colour.bodyText)
                }
            }
            InfoCard {
                developerRow
                CardRow(
                    symbol: "trash", text: Text("The old version goes to the Trash.").foregroundStyle(.secondary))
            }
            if model.appIsRunning {
                Callout(
                    symbol: "exclamationmark.circle", iconSize: Theme.Card.calloutIcon,
                    message: model.quitFailed
                        ? "\(model.appName) didn't quit. Quit it yourself, then try again."
                        : "\(model.appName) is open. Drop quits it first, then opens the new version.")
            }
            ButtonRow {
                Button("Not now") { model.send(.notNow) }.buttonStyle(SecondaryButtonStyle())
                Button(model.appIsRunning ? "Quit and Update" : "Update") { model.send(.install) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private var developerRow: some View {
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
            CardRow(
                symbol: "shield", text: Text("The installed copy isn't signed, so Drop can't compare."))
        case nil:
            HStack(spacing: Theme.Card.iconSpacing) {
                ProgressView().controlSize(.mini).frame(width: Theme.Card.rowIcon, height: Theme.Card.rowIcon)
                Text("Checking the signature…").foregroundStyle(Theme.Colour.secondaryText)
            }
        }
    }
}

// MARK: - 2 · Installing

struct InstallingBoard: View {
    let model: PanelModel

    var body: some View {
        PanelCard {
            TitleRow(icon: model.icon, title: "Installing \(model.appName)") {
                Text("To \(model.destinationName)")
            }
            VStack(spacing: Theme.Progress.spacing) {
                ProgressBar(fraction: model.progress?.fraction ?? 0)
                HStack {
                    Text(copying ? "Copying files" : "Checking the signature")
                    Spacer()
                    if let progress = model.progress { Text(Format.progress(progress)) }
                }
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Colour.secondaryText)
            }
            InfoCard {
                StepRow(title: "Read the disk image", step: .done)
                StepRow(title: "Copy \(model.appName)", step: copying ? .current : .done)
                StepRow(title: "Check the signature", step: copying ? .pending : .current)
                StepRow(title: "Move into \(model.destinationName)", step: .pending)
            }
            ButtonRow {
                Button("Cancel") { model.send(.cancelInstall) }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var copying: Bool { (model.progress?.fraction ?? 0) < 1 }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(Theme.Progress.trackOpacity))
                Capsule().fill(Theme.Colour.accent)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: Theme.Progress.height)
        .accessibilityElement()
        .accessibilityLabel("Install progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

struct StepRow: View {
    enum Step { case done, current, pending }
    let title: String
    let step: Step

    var body: some View {
        HStack(spacing: Theme.Card.iconSpacing) {
            Group {
                switch step {
                case .done:
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.Colour.good)
                case .current:
                    ProgressView().controlSize(.mini)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(Theme.Colour.tertiaryText)
                }
            }
            .font(.system(size: Theme.Card.rowIcon - 1, weight: .semibold))
            .frame(width: Theme.Card.rowIcon, height: Theme.Card.rowIcon)
            Text(title)
                .fontWeight(step == .current ? .semibold : .regular)
                .foregroundStyle(step == .current ? Theme.Colour.bodyText : Theme.Colour.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 3 · Installed

struct DoneBoard: View {
    let model: PanelModel

    var body: some View {
        PanelCard {
            TitleRow(icon: model.icon, title: "\(model.appName) is installed") {
                Text(subtitle)
            } badge: {
                Circle().fill(Theme.Colour.good)
                    .overlay(Circle().strokeBorder(Theme.Colour.onAccent, lineWidth: Theme.Icon.badgeBorder))
                    .overlay {
                        Image(systemName: "checkmark").font(.system(size: Theme.Icon.badgeGlyph, weight: .heavy))
                            .foregroundStyle(Theme.Colour.onAccent)
                    }
                    .frame(width: Theme.Icon.badge, height: Theme.Icon.badge)
                    .offset(x: Theme.Icon.badgeOffset, y: Theme.Icon.badgeOffset)
                    .accessibilityHidden(true)
            }
            if model.trashedImage != nil {
                InfoCard {
                    HStack(spacing: Theme.Card.iconSpacing) {
                        Image(systemName: "trash").font(.system(size: Theme.Card.rowIcon - 2))
                            .foregroundStyle(Theme.Colour.secondaryText)
                            .frame(width: Theme.Card.rowIcon, height: Theme.Card.rowIcon)
                        Text("Disk image moved to the Trash.").foregroundStyle(Theme.Colour.bodyText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Card.iconSpacing)
                        Button("Undo") { model.send(.undoTrash) }.buttonStyle(LinkButtonStyle())
                    }
                }
            }
            ButtonRow {
                Button("Show in Finder") { model.send(.showAppInFinder) }.buttonStyle(SecondaryButtonStyle())
                Button("Open \(model.appName)") { model.send(.openApp) }.buttonStyle(PrimaryButtonStyle())
            }
            Text("Closes on its own in a few seconds.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Colour.secondaryText)
                .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        let version = model.summary?.version.map { "Version \($0) in " } ?? "In "
        return version + model.destinationName
    }
}

// MARK: - Not notarized

struct WarningBoard: View {
    let model: PanelModel

    var body: some View {
        PanelCard {
            ImageHeader(model: model)
            TitleRow(icon: model.icon, title: model.appName) {
                Text(
                    [model.summary?.version.map { "Version \($0)" }, model.summary.map { Format.size($0.size) }]
                        .compactMap(\.self).joined(separator: " · "))
            }
            Callout(title: "Apple hasn't checked this app.", message: message)
            ButtonRow {
                Button("Install Anyway") { model.send(.installAnyway) }
                    .buttonStyle(LinkButtonStyle(colour: Theme.Colour.warning))
            } trailing: {
                Button("Show in Finder") { model.send(.showImageInFinder) }.buttonStyle(SecondaryButtonStyle())
                Button("Don't Install") { model.send(.notNow) }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var message: String {
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
            Callout(colour: Theme.Colour.error, title: copy.title, message: copy.message)
            ButtonRow {
                Button("Show in Finder") { model.send(.showImageInFinder) }.buttonStyle(SecondaryButtonStyle())
                Button("Close") { model.send(.close) }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var copy: (title: String, message: String) {
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
                Text(copy.detail).foregroundStyle(Theme.Colour.bodyText)
                    .lineSpacing(Theme.Card.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ButtonRow {
                if copy.primary != .openImage {
                    Button("Open disk image") { model.send(.openImage) }.buttonStyle(LinkButtonStyle())
                }
            } trailing: {
                Button("Not now") { model.send(.notNow) }.buttonStyle(SecondaryButtonStyle())
                Button(copy.primaryTitle) { model.send(copy.primary) }.buttonStyle(PrimaryButtonStyle())
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
            HStack(spacing: Theme.Icon.titleSpacing) {
                AppIconView(
                    icon: model.icon, size: Theme.Icon.licenceSize, cornerRadius: Theme.Icon.licenceCornerRadius,
                    glyph: Theme.Icon.licenceGlyph)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.appName)'s licence agreement").font(Theme.Font.licenceTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Agree to it to install \(model.appName).").font(Theme.Font.subtitle)
                        .foregroundStyle(Theme.Colour.secondaryText)
                }
                Spacer(minLength: 0)
                if let licence, licence.languages.count > 1 {
                    Picker("Language", selection: $model.licenceLanguage) {
                        ForEach(licence.languages.indices, id: \.self) { index in
                            Text(LicenceText.languageName(licence.languages[index], index: index)).tag(index)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            LicenceTextView(text: attributedText)
                .frame(height: Theme.Licence.textHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Licence.textCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Licence.textCornerRadius, style: .continuous)
                        .strokeBorder(Theme.Colour.separator)
                }
                .accessibilityLabel("Licence text")
            ButtonRow {
                Button("Save as PDF…") { model.send(.saveLicence) }.buttonStyle(LinkButtonStyle())
            } trailing: {
                Button("Disagree") { model.send(.disagreeLicence) }.buttonStyle(SecondaryButtonStyle())
                Button("Agree and Install") { model.send(.agreeLicence) }
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: Theme.Button.licencePrimaryPadding))
            }
        }
    }

    private var licence: LicenceAgreement? {
        if case .needsLicence(let licence) = model.state { return licence }
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

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = true
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
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .focused($focused)
                    .padding(.vertical, Theme.Password.fieldVerticalPadding)
                    .padding(.horizontal, Theme.Password.fieldHorizontalPadding)
                    .background(
                        Theme.Colour.textBackground,
                        in: RoundedRectangle(cornerRadius: Theme.Password.fieldCornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Password.fieldCornerRadius, style: .continuous)
                            .strokeBorder(Theme.Colour.accent, lineWidth: Theme.Password.fieldBorder)
                    }
                    .onSubmit { model.send(.submitPassword) }
                if case .needsPassword(let attempt) = model.state, attempt > 1 {
                    Text("That password didn't work. Try again.")
                        .font(Theme.Font.small).foregroundStyle(Theme.Colour.error)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            Text("Drop uses it once to open the image and doesn't save it.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Colour.secondaryText)
            ButtonRow {
                Button("Not now") { model.send(.notNow) }.buttonStyle(SecondaryButtonStyle())
                Button("Open") { model.send(.submitPassword) }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.password.isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}
