import AppKit
import SwiftUI

/// The SettingsWindow primitive (SettingsV2 board): a "Settings" page title inside the
/// content, then groups of SettingsRows in r14 cards. One setting per row, one caption
/// line at most, longer text behind an ⓘ, lists in a sheet, no footer notes. Pausing is
/// the Ask switch; Quit Drop is in the last group, since Drop has no menu bar menu.
struct SettingsView: View {
    @Bindable var preferences: Preferences
    let recent: [RecentInstall]
    let changeFolder: () -> Void
    let setOpenAtLogin: (Bool) -> Void
    let setOpensDiskImages: (Bool) -> Void
    let quit: () -> Void
    /// The app's version, for the last group.
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    @State private var showsRecent = false
    @Environment(\.settingsOpensRecent) private var opensRecent
    @State private var showsSkipInfo = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            page.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(width: Theme.Settings.width, height: min(max(contentHeight, 1), Theme.Settings.maxHeight))
        .ignoresSafeArea()
        .background(SurfaceBackground(kind: .settings).ignoresSafeArea())
        .foregroundStyle(Theme.Colour.bodyText)
        .sheet(isPresented: $showsRecent) { RecentSheet(recent: recent) { showsRecent = false } }
        .onChange(of: opensRecent, initial: true) { if opensRecent { showsRecent = true } }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.Font.pageTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Theme.Settings.titleToGroups)
            VStack(alignment: .leading, spacing: Theme.Settings.groupSpacing) {
                group("Watching") {
                    SwitchRow(
                        title: "Ask when a new disk image arrives", caption: "Turn off to pause watching.",
                        isOn: $preferences.askOnNewImage)
                    DisclosureRow(
                        title: "Folder", value: FileManager.default.displayName(atPath: preferences.watchedFolder.path),
                        action: changeFolder)
                }
                group("Installing") {
                    SettingsRow("Install apps to") {
                        NidusSelect(
                            label: "Install apps to", selection: preferences.installLocation,
                            options: InstallLocation.allCases, title: \.title
                        ) { preferences.installLocation = $0 }
                        .frame(minWidth: Theme.Row.selectMinWidth, alignment: .trailing)
                    }
                    SwitchRow(title: "Move the disk image to the Trash", isOn: $preferences.trashImage)
                    SwitchRow(title: "Open the app when it's installed", isOn: $preferences.openAfterInstall)
                    skipPromptRow
                }
                group("General") {
                    SwitchRow(title: "Open Drop at login", isOn: loginBinding)
                    SwitchRow(
                        title: "Open disk images with Drop", caption: "Double-click a .dmg to get the install window.",
                        isOn: handlerBinding)
                }
                group("Recent") {
                    DisclosureRow(title: "Recent installs", value: "\(recent.count)") { showsRecent = true }
                }
                group("Drop") {
                    SettingsRow(version.isEmpty ? "Drop" : "Version \(version)") {
                        Button("Quit Drop", action: quit).buttonStyle(.nidusSmall)
                    }
                }
            }
        }
        .padding(.top, Theme.Settings.titleTop)
        .padding([.horizontal, .bottom], Theme.Space.xl)
        .frame(width: Theme.Settings.width, alignment: .leading)
    }

    /// The skip-prompt switch with its ⓘ: the caption says the limit, the popover says
    /// what it does.
    private var skipPromptRow: some View {
        HStack(spacing: Theme.Row.labelControlGap) {
            VStack(alignment: .leading, spacing: Theme.Row.captionGap) {
                HStack(spacing: Theme.Row.titleInfoGap) {
                    Text("Skip the \u{201C}downloaded from the Internet\u{201D} prompt").font(Theme.Font.body)
                    Button {
                        showsSkipInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle").font(Theme.Font.chevron)
                            .foregroundStyle(Theme.Colour.secondaryText)
                    }
                    .buttonStyle(.nidusPlain)
                    .accessibilityLabel("More info")
                    .popover(isPresented: $showsSkipInfo, arrowEdge: .bottom) {
                        Text(
                            "Drop marks the app approved, as clicking Open does. Only for notarized apps that pass Drop's check, never for Install Anyway. macOS still checks the signature at first launch."
                        )
                        .font(Theme.Font.small)
                        .frame(width: Theme.Settings.infoWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Theme.Space.l)
                    }
                }
                Text("Only for apps notarized by Apple.").font(Theme.Font.caption)
                    .foregroundStyle(Theme.Colour.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            // The label is the text on the left, so the ⓘ stays its own button; the switch
            // carries the name for VoiceOver.
            Toggle(isOn: $preferences.skipFirstOpenPrompt) { EmptyView() }
                .toggleStyle(.nidusSwitch)
                .fixedSize()
                .accessibilityLabel("Skip the downloaded from the Internet prompt")
        }
        .padding(.horizontal, Theme.Row.horizontalPadding)
        .padding(.vertical, Theme.Row.verticalPadding)
    }

    /// A group label (11 medium, inset 4) 6 above its card.
    private func group<Content: View>(_ label: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Settings.labelToCard) {
            Text(label).font(Theme.Font.groupLabel).foregroundStyle(Theme.Colour.secondaryText)
                .padding(.leading, Theme.Settings.labelInset)
                .accessibilityAddTraits(.isHeader)
            RowCard(content: rows)
        }
    }

    private var handlerBinding: Binding<Bool> {
        Binding(get: { preferences.opensDiskImages }, set: { setOpensDiskImages($0) })
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { preferences.openAtLogin },
            set: {
                preferences.openAtLogin = $0
                setOpenAtLogin($0)
            })
    }
}

extension EnvironmentValues {
    /// Opens the Recent sheet as Settings appears (the demo's settings-recent state).
    @Entry var settingsOpensRecent = false
}

/// A row that opens something (a sheet, a picker): title left, value and chevron right,
/// and the whole row is the button.
struct DisclosureRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Row.labelControlGap) {
                Text(title).font(Theme.Font.body).foregroundStyle(Theme.Colour.bodyText)
                Spacer(minLength: 0)
                HStack(spacing: Theme.Row.titleInfoGap) {
                    Text(value).font(Theme.Font.body).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(Theme.Font.chevron)
                }
                .foregroundStyle(Theme.Colour.secondaryText)
            }
            .padding(.horizontal, Theme.Row.horizontalPadding)
            .padding(.vertical, Theme.Row.verticalPadding)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nidusPlain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// The Recent sheet (Sheet primitive, 560 × 480): the apps Drop installed, newest first,
/// each with Show; Done closes it (Return or Esc).
struct RecentSheet: View {
    let recent: [RecentInstall]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent installs").font(Theme.Font.sectionTitle).accessibilityAddTraits(.isHeader)
            Text("Apps Drop installed, newest first.").font(Theme.Font.body)
                .foregroundStyle(Theme.Colour.secondaryText)
                .padding(.top, Theme.Space.s)
            ScrollView {
                RowCard {
                    if recent.isEmpty {
                        Text("Nothing installed yet.").font(Theme.Font.body)
                            .foregroundStyle(Theme.Colour.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: Theme.Settings.recentRowHeight, alignment: .leading)
                            .padding(.horizontal, Theme.Row.horizontalPadding)
                    }
                    ForEach(recent) { install in
                        HStack(spacing: Theme.Settings.rowSpacing) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: install.path))
                                .resizable()
                                .frame(width: Theme.Icon.recentSize, height: Theme.Icon.recentSize)
                                .accessibilityHidden(true)
                            Text(install.title).font(Theme.Font.body).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(Format.relative(install.date)).font(Theme.Font.small)
                                .foregroundStyle(Theme.Colour.secondaryText)
                            Button("Show") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: install.path)])
                            }
                            .buttonStyle(.nidusLink())
                        }
                        .frame(minHeight: Theme.Settings.recentRowHeight)
                        .padding(.horizontal, Theme.Row.horizontalPadding)
                    }
                }
            }
            .padding(.top, Theme.Space.l)
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(.nidusPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Theme.Space.l)
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Settings.sheetWidth, height: Theme.Settings.sheetHeight)
        .foregroundStyle(Theme.Colour.bodyText)
        .background(SurfaceBackground(kind: .settings))
        .onExitCommand(perform: done)
    }
}

/// The Settings window. While it's open Drop has a Dock icon and is in Command-Tab
/// (`ActivationPolicy`).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> AnyView
    /// Runs before each show, to refresh values that live outside Drop.
    private let onShow: () -> Void

    init(makeView: @escaping () -> AnyView, onShow: @escaping () -> Void = {}) {
        self.makeView = makeView
        self.onShow = onShow
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) { ActivationPolicy.closed(.settings) }

    var windowNumber: Int? { window?.windowNumber }

    func show() {
        onShow()
        if window == nil {
            let controller = NSHostingController(rootView: makeView())
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.paintsSurfaceUnderTitleBar()
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        } else if let controller = window?.contentViewController as? NSHostingController<AnyView> {
            controller.rootView = makeView()
        }
        guard let window else { return }
        window.layoutIfNeeded()
        Self.centre(window)
        ActivationPolicy.opened(.settings)
        WindowPresence.present(window)
    }

    /// Shows the Recent sheet, for screenshots of it.
    func presentRecent() {
        guard let controller = window?.contentViewController as? NSHostingController<AnyView> else { return }
        controller.rootView = AnyView(makeView().environment(\.settingsOpensRecent, true))
    }

    /// Centres `window` in the visible frame of the active screen, every time it opens:
    /// the screen with the key window, else the one whose menu bar is active
    /// (`NSScreen.main`). `NSWindow.center()` sits a third from the top and only on the
    /// window's own screen, so Settings could open on a display the user isn't using.
    static func centre(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}
