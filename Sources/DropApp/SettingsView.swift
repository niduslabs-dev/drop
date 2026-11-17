import AppKit
import SwiftUI

/// The SettingsWindow primitive (SettingsV2 board): a "Settings" page title inside the
/// content, then groups of SettingsRows in r14 cards. One setting per row, one caption
/// line at most, longer text behind an ⓘ, lists in a sheet, no footer notes. Pausing is
/// the Ask switch; Quit Drop is in the last group, since Drop has no menu bar menu. While an
/// update waits for a restart its banner leads the page (Updates board).
struct SettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var updates: UpdateModel
    let changeFolder: () -> Void
    let setOpenAtLogin: (Bool) -> Void
    let setOpensDiskImages: (Bool) -> Void
    let quit: () -> Void
    /// The app's version, for the last group.
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    @Environment(\.titleBarHeight) private var titleBarHeight
    @Environment(\.settingsSizing) private var sizing
    @State private var showsSkipInfo = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Environment(\.settingsDemoOffset) private var demoOffset

    /// The scroll view fills the window below the title bar, and the window controller
    /// sizes the window to the page (`SettingsSizing`), so the page's own insets are the
    /// only space around it. It bounces at both ends even when everything
    /// fits, like a native settings pane, and rows scrolled up under the title bar fade out
    /// before they reach the traffic lights.
    var body: some View {
        ScrollView {
            page.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                sizing?.contentHeightChanged(titleBarHeight + $0)
            }
        }
        .scrollPosition($scrollPosition)
        .onChange(of: demoOffset, initial: true) { if let demoOffset { scrollPosition.scrollTo(y: demoOffset) } }
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollIndicators(.automatic)
        .mask { scrollEdgeMask }
        .frame(width: Theme.Settings.width)
        .frame(maxHeight: .infinity)
        .padding(.top, titleBarHeight)
        .background(SurfaceBackground(kind: .settings).ignoresSafeArea())
        .foregroundStyle(Theme.Colour.bodyText)
    }

    /// The scroll-edge effect. The scroll view starts below the title bar and clips there,
    /// so no row can reach the traffic lights; over its first `scrollEdgeFade` points rows
    /// fade out instead of being cut off. A mask, not a band painted on top, so what shows
    /// through is the window's own backdrop: a second ink glass or window colour over the
    /// first would read as a darker band (titleBarMatchesContent). At rest the fade ends at
    /// the page title, so nothing is faded.
    private var scrollEdgeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Theme.Settings.scrollEdgeFade)
            Color.black
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.Font.pageTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Theme.Settings.titleToGroups)
            VStack(alignment: .leading, spacing: Theme.Settings.groupSpacing) {
                if updates.isReady { UpdateBanner(model: updates) }
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
                            options: InstallLocation.selectOptions
                        ) { preferences.installLocation = $0 }
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
                group("Drop") {
                    // The caption reads the clock when the page draws; Settings is redrawn on
                    // every open and on each update event, which is often enough for "today".
                    SettingsRow(version.isEmpty ? "Drop" : "Version \(version)", caption: updates.versionCaption()) {
                        Button("Check for Updates") { updates.perform(.check) }.buttonStyle(.nidusSmall)
                            .disabled(!updates.isEnabled || updates.phase == .checking)
                    }
                    SwitchRow(
                        title: "Install updates automatically",
                        caption: "Downloads in the background and installs when Drop quits.",
                        isOn: $updates.automatic)
                    SettingsRow("Quit Drop") {
                        Button("Quit", action: quit).buttonStyle(.nidusSmall)
                    }
                }
            }
        }
        .padding(.top, Theme.Settings.titleBarGap)
        .padding([.horizontal, .bottom], Theme.Settings.inset)
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
            Toggle("Skip the downloaded from the Internet prompt", isOn: $preferences.skipFirstOpenPrompt)
                .toggleStyle(.nidusSwitch)
                .labelsHidden()
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
    /// Debug: scrolls the Settings page to this offset (`demoScroll`).
    @Entry var settingsDemoOffset: CGFloat?
    /// Where the Settings page reports its height (`SettingsSizing`).
    @Entry var settingsSizing: SettingsSizing?
}

/// Takes the Settings window's full content height (title bar, then the page with its gap
/// and insets) to the window controller, which sizes the window to it up to
/// `Theme.Settings.maxHeight`. A class, not a closure, in the environment: SwiftUI compares
/// it by identity, so it doesn't invalidate the page on every update.
@MainActor
final class SettingsSizing {
    let contentHeightChanged: (CGFloat) -> Void

    init(contentHeightChanged: @escaping (CGFloat) -> Void) { self.contentHeightChanged = contentHeightChanged }
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

/// The Settings window. While it's open Drop has a Dock icon and is in Command-Tab
/// (`ActivationPolicy`).
///
/// The window is as tall as the page, up to `Theme.Settings.maxHeight`, past which the page
/// scrolls. SwiftUI reports the page's height and this controller sets the frame, rather
/// than the hosting controller's preferred size: that path counted the title bar's safe
/// area on top of a page that already leaves room for it, which left a gap under the last
/// card.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingView<AnyView>?
    private let makeView: () -> AnyView
    /// Runs before each show, to refresh values that live outside Drop.
    private let onShow: () -> Void
    /// The content height last reported (title bar and page), 0 until the page has laid out.
    private var contentHeight: CGFloat = 0
    /// Set by `show()` until the window has its size: it's centred and brought forward then.
    private var presentPending = false
    private lazy var sizing = SettingsSizing { [weak self] height in self?.contentHeightChanged(height) }

    init(makeView: @escaping () -> AnyView, onShow: @escaping () -> Void = {}) {
        self.makeView = makeView
        self.onShow = onShow
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) { ActivationPolicy.closed(.settings) }

    var windowNumber: Int? { window?.windowNumber }

    func show() {
        onShow()
        let window = self.window ?? makeWindow()
        hosting?.rootView = root(makeView())
        presentPending = true
        hosting?.layoutSubtreeIfNeeded()
        // A reopen with the page unchanged reports no new height: use the last one.
        if contentHeight > 0 { resize(window, to: contentHeight) }
    }

    private func makeWindow() -> NSWindow {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Settings.width, height: Theme.Settings.maxHeight),
            styleMask: styleMask, backing: .buffered, defer: false)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.paintsSurfaceUnderTitleBar()
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // No saved frame or restored state: Settings always opens centred (`centre`).
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.delegate = self
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        // The page places itself below the title bar (`titleBarHeight`), so SwiftUI gets no
        // safe area of its own to inset by.
        hosting.safeAreaRegions = []
        window.contentView = hosting
        self.window = window
        self.hosting = hosting
        return window
    }

    /// `view` with the window's real title bar height and the height callback.
    private func root(_ view: AnyView) -> AnyView {
        guard let window else { return view }
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        return AnyView(
            view
                .environment(\.titleBarHeight, titleBarHeight)
                .environment(\.settingsSizing, sizing)
                .displayOptions())
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, let window else { return }
        contentHeight = height
        resize(window, to: height)
    }

    /// Sizes the window to the page, up to the maximum, then centres it: the size has to
    /// be known first, since a later resize keeps the old origin and leaves the window off
    /// centre (the bug this replaced). Every resize re-centres, so a later height change
    /// can't push it off either. The first size after `show()` also brings it forward.
    private func resize(_ window: NSWindow, to height: CGFloat) {
        let size = NSSize(width: Theme.Settings.width, height: min(height, Theme.Settings.maxHeight))
        guard presentPending || window.frame.size != size else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: !presentPending)
        Self.centre(window)
        if presentPending {
            presentPending = false
            ActivationPolicy.opened(.settings)
            WindowPresence.present(window)
        }
    }

    #if DEBUG
        /// Where `--demo settings-…` scrolls the page to for screenshots.
        enum DemoScroll {
            /// Halfway down (the top, when the page fits).
            case middle
            /// Scrolled to the end, to measure the inset under the last card.
            case bottom
        }

        /// Scrolls the page to `position` without moving the pointer, so a background test
        /// can capture scrolled states. It goes through SwiftUI's own scroll position
        /// (`settingsDemoOffset`), the path a real scroll takes, so the clip and the edge
        /// fade are what a user sees.
        func demoScroll(_ position: DemoScroll) {
            let range = max(contentHeight - Theme.Settings.maxHeight, 0)
            let offset = position == .middle ? range / 2 : range
            hosting?.rootView = root(AnyView(makeView().environment(\.settingsDemoOffset, offset)))
        }

        /// The title bar height the page is laid out below, for the measuring scripts.
        var titleBarHeight: CGFloat { window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0 }

        /// Closes and reopens the window, for checking where a reopen lands.
        func demoReopen() {
            window?.close()
            show()
        }
    #endif

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
