import AppKit
import Extractor
import Mounter
import Onboarding
import ServiceManagement
import SwiftUI

/// Drop's lifecycle: no Dock or menu bar icon (`LSUIElement`), a Downloads watcher, the
/// popup and the centred window. Opening Drop again while it runs shows Settings; pausing
/// is Settings' Ask switch and quitting is Settings' Quit Drop. Disk images reach Drop by
/// Open With, a double-click when it's the default, or a drop on its icon in Finder.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted by a second copy of Drop that was started while this one runs.
    /// "Show Settings", from a second launch to the running copy. Named after the bundle
    /// ID, so a debug copy (`dev.niduslabs.drop.debug`) and a release copy never hear each
    /// other: the release name stays `dev.niduslabs.drop.showSettings`.
    static let showSettingsNotification = Notification.Name(
        (Bundle.main.bundleIdentifier ?? "dev.niduslabs.drop") + ".showSettings")

    let launch: LaunchOptions
    let preferences: Preferences
    let store: Store
    /// The preferences domain: the app's, or the test domain in test launches. Settings and
    /// onboarding's state both live here.
    let defaults: UserDefaults

    /// Test launches (`--watch`, `--destination`, `--trash`, `--demo`) keep their settings
    /// and handled list apart from the real ones, so a test never hides a real
    /// download.
    override init() {
        let launch = LaunchOptions()
        self.launch = launch
        if launch.isTesting {
            defaults = UserDefaults(suiteName: Self.testSuite) ?? .standard
            preferences = Preferences(defaults: defaults)
            store = Store(
                directory: FileManager.default.temporaryDirectory.appending(
                    path: Self.testSuite, directoryHint: .isDirectory))
        } else {
            defaults = .standard
            preferences = Preferences()
            store = Store()
        }
        #if DEBUG
            if launch.resetOnboarding { OnboardingCoordinator.reset(in: defaults) }
        #endif
        super.init()
    }

    static let testSuite = "dev.niduslabs.drop.test"
    private(set) var panel: PanelWindowController!
    private(set) var controller: InstallController!
    private(set) var settings: SettingsWindowController!
    private var watcher: DownloadsWatcher?
    private(set) var onboarding: OnboardingCoordinator!
    private(set) var onboardingWindow: OnboardingWindowController?
    /// Disk images opened before launch finished (Open With starts Drop with them).
    private var pendingOpens: [URL] = []
    private var isLaunched = false

    /// In a background test, Open Documents events come to `handleOpenDocuments` instead of
    /// AppKit's own handler, which activates the app (measured: Drop became the active app
    /// within 0.15 s of an `odoc` sent straight to its PID) and so would take focus.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard launch.isBackgroundTest else { return }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    /// The background test's Open Documents: the event's file URLs, into `application(_:open:)`.
    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let urls = (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.fileURLValue }
        application(NSApp, open: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            if let appearance = launch.appearance {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
        #endif
        Typeface.registerBundledFonts()
        FocusVisibility.shared.start()
        panel = PanelWindowController()
        controller = InstallController(preferences: preferences, store: store, launch: launch, panel: panel)
        settings = SettingsWindowController { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                SettingsView(
                    preferences: self.preferences,
                    changeFolder: { [weak self] in self?.chooseWatchedFolder() },
                    setOpenAtLogin: { [weak self] in self?.setLoginItem($0) },
                    setOpensDiskImages: { [weak self] in self?.setOpensDiskImages($0) },
                    quit: { NSApp.terminate(nil) }))
        } onShow: { [weak self] in
            self?.preferences.opensDiskImages = DiskImageHandler.isDropDefault
        }
        // A background test copy never answers another launch: a release test build shares
        // the release name, and a launch of the user's own copy must not open a window here.
        if !launch.isBackgroundTest {
            DistributedNotificationCenter.default().addObserver(
                forName: Self.showSettingsNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.showSettingsOrOnboarding() }
            }
        }

        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettingsFromMenu(_:)))

        isLaunched = true
        for url in pendingOpens { controller.enqueue(url, origin: .opened) }
        pendingOpens.removeAll()

        #if DEBUG
            if launch.probeHandler {
                Task {
                    let before = DiskImageHandler.isDropDefault
                    let after = await DiskImageHandler.setDropDefault(true)
                    print("PROBE before=\(before) after=\(after)")
                    fflush(stdout)
                }
                return
            }
            if let demo = launch.demo {
                Demo.run(demo, app: self)
                return
            }
        #endif

        sweepLeftovers()
        if !launch.manageLoginItem {
            Log.app.info("Login item left alone (test launch); status \(SMAppService.mainApp.status.rawValue)")
        }
        preferences.opensDiskImages = DiskImageHandler.isDropDefault
        observePreferences()
        startOnboarding()
        updateWatcher()
    }

    // MARK: Onboarding

    /// Builds the coordinator and shows onboarding when it's due. Test launches get stand-ins
    /// that leave the real default handler and login item alone, and list the real folder
    /// only when it's a `--watch` test folder, never `~/Downloads`.
    private func startOnboarding() {
        let access: any FolderAccessChecking =
            launch.isTesting && launch.watchFolder == nil
            ? DeniedFolderAccess() : ListingFolderAccess()
        let coordinator = OnboardingCoordinator(
            defaults: defaults, folderAccess: access,
            defaultHandler: launch.isTesting ? TestDefaultHandler() : LiveDefaultHandler(),
            loginItem: launch.manageLoginItem ? LiveLoginItem() : TestLoginItem())
        coordinator.onWatchingAllowed = { [weak self] in self?.updateWatcher() }
        coordinator.onFolderChosen = { [weak self] in self?.preferences.watchedFolder = $0 }
        coordinator.onDefaultHandlerChanged = { [weak self] in self?.preferences.opensDiskImages = $0 }
        coordinator.onLoginItemChosen = { [weak self] in self?.preferences.openAtLogin = $0 }
        coordinator.onEnd = { [weak self] in
            self?.onboardingWindow?.close()
            self?.updateWatcher()
        }
        onboarding = coordinator
        guard !launch.skipsOnboarding, coordinator.showsAtLaunch else { return }
        coordinator.reopened()
        showOnboarding(coordinator)
    }

    /// Opens the onboarding window for `coordinator` (the app's, or a demo's).
    func showOnboarding(_ coordinator: OnboardingCoordinator) {
        let window = OnboardingWindowController(coordinator: coordinator) { [weak self] close in
            OnboardingView(
                coordinator: coordinator,
                folder: { [weak self] in self?.watchedFolder ?? FileManager.default.homeDirectoryForCurrentUser },
                chooseFolder: { [weak self] in self?.chooseOnboardingFolder() },
                openPrivacySettings: { NSWorkspace.shared.open(Self.filesAndFoldersSettings) },
                close: close)
        }
        onboardingWindow = window
        window.show()
    }

    /// System Settings › Privacy & Security › Files and Folders.
    static let filesAndFoldersSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// Choose another folder. Starts in the home folder, not the watched one: showing
    /// `~/Downloads` in the panel would be an access of its own.
    private func chooseOnboardingFolder() -> URL? {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        open.prompt = "Watch"
        guard open.runModal() == .OK else { return nil }
        return open.url
    }

    /// Settings… (⌘,) in the main menu: opens Settings, centred.
    @objc func openSettingsFromMenu(_ sender: Any?) { settings.show() }

    /// Opening Drop again, or clicking its Dock icon, brings forward the window that's
    /// open (onboarding first, then the install window, then Settings), else opens Settings.
    private func showSettingsOrOnboarding() {
        if let onboardingWindow, onboardingWindow.isVisible {
            onboardingWindow.show()
        } else if panel.isWindowVisible, !settings.isVisible {
            panel.bringWindowForward()
        } else {
            settings.show()
        }
    }

    /// Open With › Drop, or a double-click when Drop is the default for disk images. An
    /// explicit open always gets a panel, even for an image dismissed or installed before.
    func application(_ application: NSApplication, open urls: [URL]) {
        let images = urls.filter(\.isFileURL)
        guard isLaunched else {
            pendingOpens += images
            return
        }
        for url in images { controller.enqueue(url, origin: .opened) }
    }

    private func setOpensDiskImages(_ on: Bool) {
        preferences.opensDiskImages = on
        Task {
            preferences.opensDiskImages = await DiskImageHandler.setDropDefault(on)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsOrOnboarding()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        controller?.detachInstallerMounts()
    }

    var watchedFolder: URL { launch.watchFolder ?? preferences.watchedFolder }
    private var watchedFolderName: String { FileManager.default.displayName(atPath: watchedFolder.path) }

    /// Clears staging areas and hidden mounts a crash or force quit left behind.
    private func sweepLeftovers() {
        let destinations = launch.destination.map { [$0] } ?? InstallLocation.allCases.map(\.url)
        for destination in destinations where FileManager.default.fileExists(atPath: destination.path) {
            Extractor.sweepLeftovers(near: destination) { removed in
                if removed > 0 { Log.app.info("Removed \(removed) leftover staging areas") }
            }
        }
        Task.detached(priority: .utility) {
            let devices = HiddenMount.sweepLeftoverMounts()
            if !devices.isEmpty { Log.app.info("Detached \(devices.count) leftover hidden mounts") }
        }
    }

    // MARK: Watching

    /// Starts or stops the watcher to match the settings. Waits for onboarding: starting it
    /// is Drop's first access to the watched folder (see `OnboardingCoordinator`).
    private func updateWatcher() {
        let allowed = launch.skipsOnboarding || (onboarding?.allowsWatching ?? false)
        let wanted = allowed && preferences.askOnNewImage
        if let watcher, watcher.folder == watchedFolder.standardizedFileURL, watcher.isRunning == wanted { return }
        watcher?.stop()
        watcher = nil
        guard wanted else { return }
        let name = watchedFolderName
        let watcher = DownloadsWatcher(folder: watchedFolder) { [weak self] url in
            self?.controller.enqueue(url, origin: .watched(folderName: name))
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Re-applies settings whenever one changes.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.askOnNewImage
            _ = preferences.watchedFolder
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateWatcher()
                self.observePreferences()
            }
        }
    }

    private func chooseWatchedFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = preferences.watchedFolder
        open.prompt = "Watch"
        guard open.runModal() == .OK, let url = open.url else { return }
        preferences.watchedFolder = url
    }

    // MARK: Login item

    /// Registers or removes the login item. A failure (an ad hoc build outside
    /// Applications, or the user turned it off in System Settings) is logged, never shown:
    /// the switch stays as the user set it and Drop works either way while it runs.
    func setLoginItem(_ on: Bool) {
        guard launch.manageLoginItem else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("Login item \(on ? "on" : "off"); status \(SMAppService.mainApp.status.rawValue)")
        } catch {
            Log.app.error("Login item \(on ? "register" : "unregister") failed: \(error, privacy: .public)")
        }
    }
}
