import AppKit
import Installer
import Mounter
import UniformTypeIdentifiers

/// Drives one `InstallSession` per DMG and shows its panel: the popup for a watched download,
/// the centred window for an opened image. DMGs that arrive while a panel is up wait in a
/// queue: one panel at a time, and only the shown one is read and staged, so several
/// downloads never stage at once in the background.
@MainActor
final class InstallController {
    private let preferences: Preferences
    private let store: Store
    private let launch: LaunchOptions
    private let panel: PanelWindowController
    private let updateCheck: UpdateCheck
    /// The running Drop, to recognise its own disk image (`SelfImage`).
    private let running: SelfImage.Running

    private var queue: [(url: URL, origin: PanelModel.Origin)] = []
    private var current: PanelModel?
    private var session: InstallSession?
    private var updatesTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// Images attached for Open Installer; kept until Installer quits or Drop does.
    private var installerMounts: [HiddenMount] = []
    private var installerObserver: NSObjectProtocol?
    /// When board 2 first showed for the current model, for `Theme.Motion.installingHold`.
    private var installingShownAt: ContinuousClock.Instant?
    /// The current panel is on its way out before its app opens (`AfterInstall`): its
    /// buttons and Esc do nothing, so a click can't land on a surface that's leaving.
    private var isClosingToOpen = false

    init(
        preferences: Preferences, store: Store, launch: LaunchOptions, panel: PanelWindowController,
        updateCheck: UpdateCheck, running: SelfImage.Running = .current
    ) {
        self.updateCheck = updateCheck
        self.running = running
        self.preferences = preferences
        self.store = store
        self.launch = launch
        self.panel = panel
        panel.onDismiss = { [weak self] model in self?.handle(Self.dismissAction(for: model), for: model) }
    }

    /// What Esc and the window's close button mean on each board.
    private static func dismissAction(for model: PanelModel) -> PanelAction {
        switch model.board {
        case .done, .refused: .close
        case .installing: .cancelInstall
        case .main, .update: model.isQuitting ? .cancelInstall : .notNow
        case .licence: .disagreeLicence
        default: .notNow
        }
    }

    /// The destination folder: `--home-destination` or `--destination` in tests, else the
    /// chosen location.
    private func destination(for location: InstallLocation) -> URL {
        let home = location == .homeApplications ? launch.homeDestination : nil
        return home ?? launch.destination ?? location.url
    }

    /// The folder name the panel shows: the location's, or a test folder's own name.
    private func destinationName(for location: InstallLocation) -> String {
        launch.destination == nil && launch.homeDestination == nil
            ? location.shortName : destination(for: location).lastPathComponent
    }

    /// The destination for `location`, made first when it is `~/Applications` and missing
    /// (a test folder is never made).
    private func preparedDestination(for location: InstallLocation) -> URL {
        let destination = destination(for: location)
        if location == .homeApplications, !launch.usesTestFolders {
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        return destination
    }

    // MARK: Queue

    /// A DMG to offer. Files already handled (installed, Not now) are ignored when they
    /// come from the watcher; an explicit open (Open With, a double-click when Drop is the
    /// default, a drop on the app icon) always asks.
    func enqueue(_ url: URL, origin: PanelModel.Origin) {
        let url = url.standardizedFileURL
        if case .watched = origin, let file = HandledFile(url: url), store.isHandled(file) { return }
        guard current?.dmg != url, !queue.contains(where: { $0.url == url }) else { return }
        queue.append((url, origin))
        if current == nil { startNext() }
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let model = PanelModel(
            dmg: next.url, origin: next.origin, location: preferences.installLocation,
            trashImage: preferences.trashImage)
        model.destinationName = destinationName(for: model.location)
        model.send = { [weak self, weak model] action in
            guard let self, let model else { return }
            self.handle(action, for: model)
        }
        current = model
        installingShownAt = nil
        startSession(for: model)
        // Up at once with the file name and "Reading…"; the boards fill in as the session
        // reads the image, so the popup never waits for the image to open.
        panel.show(model)
        model.latency = LatencyMarks(dmg: model.dmg)
    }

    private func startSession(for model: PanelModel) {
        let destination = preparedDestination(for: model.location)
        let trashFolder = launch.trashFolder
        let options = InstallOptions(
            destination: destination, stagingPriority: model.origin == .opened ? .userInitiated : .background,
            skipFirstLaunchPrompt: preferences.skipFirstOpenPrompt,
            trash: { url in _ = try Self.trash(url, into: trashFolder) },
            mountFallback: { dmg, reason in
                Log.app.info("Hidden mount for \(dmg.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            },
            // Ready on arrival: stage at full speed while the panel is up, so the full check
            // usually ends before Install; Low Power Mode and heat still wait.
            fullSpeedWhenUnconstrained: true,
            notarizationLookupTimeout: Theme.Timing.notarizationLateAnswer)
        let session = InstallSession(dmg: model.dmg, options: options)
        self.session = session
        updatesTask = Task { [weak self] in
            await session.start()
            for await state in session.updates {
                guard let self, self.session === session else { return }
                if case .installed = state, let shown = self.installingShownAt, !model.skipsProgress {
                    let remaining = Theme.Motion.installingHold - (ContinuousClock.now - shown)
                    if remaining > .zero { try? await Task.sleep(for: remaining) }
                    guard self.session === session else { return }
                }
                self.apply(state, to: model, session: session)
            }
        }
    }

    private func apply(_ state: InstallState, to model: PanelModel, session: InstallSession) {
        if case .needsLicence(let licence, _) = state, !(model.state.isLicence) {
            model.licenceLanguage = LicenceText.initialLanguage(licence)
        }
        let hadSummary = model.summary != nil
        model.state = state
        model.noteProgress()
        model.latency?.observe(model)
        if !hadSummary, model.summary != nil {
            Log.panel.info("summary shown \(model.dmg.lastPathComponent, privacy: .public)")
        }
        if case .installing = state, installingShownAt == nil { installingShownAt = .now }
        if model.selfImage == nil, let summary = state.summary,
            let offer = SelfImage.offer(for: summary, running: running)
        {
            showSelfImage(offer, model: model, session: session)
            return
        }
        refreshRunningApp(for: model)
        switch state {
        case .reading:
            return
        case .cancelled:
            finish(model)
            return
        case .installed(let app):
            installed(app, model: model, session: session)
        case .identified, .preparing, .waitingToPrepare, .ready:
            if model.installWhenReady {
                model.installWhenReady = false
                install(model)
            }
        default:
            break
        }
        if model.board != .hidden {
            if panel.model !== model { panel.show(model) }
            if model.board == .password { panel.focus() }
        }
    }

    /// Drop's own disk image: the name, version, icon and bundle ID are all it needs, so the
    /// session stops here, before anything is staged, and its later states are ignored.
    private func showSelfImage(_ offer: SelfImage, model: PanelModel, session: InstallSession) {
        model.selfImage = offer
        if self.session === session {
            self.session = nil
            updatesTask?.cancel()
            updatesTask = nil
            Task { await session.cancel() }
        }
        if panel.model !== model { panel.show(model) }
    }

    private func refreshRunningApp(for model: PanelModel) {
        guard let summary = model.summary, summary.update != nil, let bundleID = summary.bundleIdentifier else {
            model.appIsRunning = false
            return
        }
        model.appIsRunning = runningCopy(bundleID: bundleID, bundleName: summary.bundleName, model: model) != nil
    }

    /// The installed copy, running: same bundle ID, launched from the destination.
    private func runningCopy(bundleID: String, bundleName: String, model: PanelModel) -> NSRunningApplication? {
        let installed = destination(for: model.location).appending(path: bundleName).standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            $0.bundleURL?.standardizedFileURL.path == installed
        }
    }

    // MARK: Actions

    private func handle(_ action: PanelAction, for model: PanelModel) {
        guard model === current, !isClosingToOpen else { return }
        switch action {
        case .install, .installAnyway:
            if model.installStartedAt == nil { model.installStartedAt = .now }
            if let remaining = model.estimatedRemaining, remaining < Theme.Motion.skipProgressBelow {
                model.skipsProgress = true
            }
            if case .reading = model.state {
                model.installWhenReady = true
            } else {
                install(model)
            }
        case .cancelInstall:
            // Esc and the close button reach here too: once the copy is being swapped into
            // place, cancelling has to wait for it like the button does.
            guard model.buttons.secondary.isEnabled || model.board != .installing else { return }
            dismiss(model)
        case .notNow, .disagreeLicence: dismiss(model)
        case .close: finish(model)
        case .openImage:
            DiskImageHandler.openWithMounter(model.dmg)
            dismiss(model)
        case .openInstaller: openInstaller(model)
        case .showImageInFinder: NSWorkspace.shared.activateFileViewerSelecting([model.dmg])
        case .showAppInFinder:
            if let app = model.installedApp { NSWorkspace.shared.activateFileViewerSelecting([app]) }
            finish(model)
        case .openApp:
            if let app = model.installedApp { NSWorkspace.shared.open(app) }
            finish(model)
        case .undoTrash: undoTrash(model)
        case .agreeLicence:
            if model.installStartedAt == nil { model.installStartedAt = .now }
            model.licenceAccepted = true
            model.installWhenReady = true
            Task { await session?.acceptLicence() }
        case .saveLicence: saveLicence(model)
        case .submitPassword:
            let password = model.password
            model.password = ""
            guard !password.isEmpty else { return }
            Task { await session?.providePassword(password) }
        case .checkForUpdates:
            finish(model)
            updateCheck.run()
        }
    }

    /// Install, Update, or Quit and Update: one press runs to installed (`QuitThenInstall`).
    private func install(_ model: PanelModel) {
        guard let session, !model.isBusy, !model.isQuitting else { return }
        Task {
            guard current === model else { return }
            var running: NSRunningApplication?
            if let summary = model.summary, summary.update != nil, let bundleID = summary.bundleIdentifier {
                running = runningCopy(bundleID: bundleID, bundleName: summary.bundleName, model: model)
            }
            model.reopenAfterInstall = false
            let sequence = QuitThenInstall(
                running: running.map(RunningApp.init),
                isCurrent: { [weak self] in self?.current === model },
                show: { [weak self] step in
                    switch step {
                    case .quitting:
                        model.quitFailed = false
                        model.isQuitting = true
                    case .installing:
                        model.isQuitting = false
                        model.reopenAfterInstall = running != nil
                        self?.refreshRunningApp(for: model)
                    case .quitFailed:
                        model.isQuitting = false
                        model.quitFailed = true
                        self?.refreshRunningApp(for: model)
                    }
                },
                install: {
                    // The check can end in a warning while the app was quitting. That board
                    // asks first (Install Anyway), so the press that came before it must
                    // not install past it.
                    if case .warning = model.state, running != nil { return }
                    await session.install()
                })
            _ = await sequence.run()
        }
    }

    private func installed(_ app: URL, model: PanelModel, session: InstallSession) {
        model.installedApp = app
        if case .watched = model.origin { store.markHandled(model.dmg) }
        let plan = AfterInstallPlan(
            openAfterInstall: preferences.openAfterInstall, wasRunning: model.reopenAfterInstall)
        let trashFolder = launch.trashFolder
        // The image is trashed whether or not the panel is still up to offer Undo.
        let trashing = Task {
            guard model.trashImage else { return }
            await session.waitUntilDone()
            do {
                model.trashedImage = try Self.trash(model.dmg, into: trashFolder)
            } catch {
                Log.app.error("Couldn't trash the disk image: \(error, privacy: .public)")
            }
        }
        Task {
            switch await afterInstall(for: model).run(plan, app: app) {
            case .closed:
                finish(model)
            case .showsInstalled:
                await trashing.value
                // The popup closes by itself after a while; the window the user opened never does.
                if case .watched = model.origin, current === model { scheduleAutoClose(model) }
            case .superseded:
                break
            }
        }
    }

    /// `AfterInstall` over the real panel and Launch Services, for `model`.
    private func afterInstall(for model: PanelModel) -> AfterInstall {
        AfterInstall(
            hold: { try? await Task.sleep(for: Theme.Motion.installedHold) },
            hideSurface: { [weak self] in
                guard let self, self.current === model else { return false }
                self.isClosingToOpen = true
                guard await self.panel.hideForOpen(), self.current === model else {
                    if self.current === model { self.isClosingToOpen = false }
                    return false
                }
                return true
            },
            restoreSurface: { [weak self] in
                guard let self, self.current === model else { return }
                self.isClosingToOpen = false
                self.panel.restoreHidden()
            },
            open: AfterInstall.openApplication)
    }

    private func scheduleAutoClose(_ model: PanelModel) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Theme.Timing.doneAutoClose)
            // Wait while the pointer is over the panel, so Undo stays reachable.
            while model.isHovered, !Task.isCancelled { try? await Task.sleep(for: Theme.Timing.hoverRecheck) }
            guard !Task.isCancelled, let self, self.current === model else { return }
            self.finish(model)
        }
    }

    private func undoTrash(_ model: PanelModel) {
        guard let trashed = model.trashedImage else { return }
        do {
            try FileManager.default.moveItem(at: trashed, to: model.dmg)
            model.trashedImage = nil
        } catch {
            Log.app.error("Couldn't put the disk image back: \(error, privacy: .public)")
        }
    }

    /// Moves `url` to the Trash, or into `folder` in tests. Returns where it went.
    nonisolated static func trash(_ url: URL, into folder: URL?) throws -> URL? {
        guard let folder else {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = folder.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Not now, Disagree, Cancel, Don't Install: deletes the staged copy, remembers the file.
    private func dismiss(_ model: PanelModel) {
        let session = session
        finish(model)
        Task { await session?.notNow() }
    }

    private func finish(_ model: PanelModel) {
        guard current === model else { return }
        closeTask?.cancel()
        isClosingToOpen = false
        if case .watched = model.origin { store.markHandled(model.dmg) }
        if let session, !model.state.isFinal { Task { await session.cancel() } }
        updatesTask?.cancel()
        updatesTask = nil
        session = nil
        current = nil
        panel.close()
        startNext()
    }

    // MARK: Open Installer

    /// Attaches the image hidden and opens its package in Installer. The image stays
    /// attached until Installer quits (or Drop does), then is detached.
    private func openInstaller(_ model: PanelModel) {
        guard case .cannotInstall(.packageOnly(let names)) = model.state, let name = names.first else { return }
        let dmg = model.dmg
        let accepted = model.licenceAccepted
        model.isBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try HiddenMount.attach(dmg, licenceAccepted: accepted) }
            }.value
            model.isBusy = false
            switch result {
            case .success(let mount):
                installerMounts.append(mount)
                watchInstaller()
                let package = mount.mountPoint.appending(path: name)
                let installer = URL(filePath: "/System/Library/CoreServices/Installer.app")
                do {
                    _ = try await NSWorkspace.shared.open(
                        [package], withApplicationAt: installer, configuration: NSWorkspace.OpenConfiguration())
                } catch {
                    Log.app.error("Couldn't open Installer: \(error, privacy: .public)")
                }
                finish(model)
            case .failure(let error):
                Log.app.error("Couldn't attach for Installer: \(error, privacy: .public)")
                DiskImageHandler.openWithMounter(dmg)
                finish(model)
            }
        }
    }

    private func watchInstaller() {
        guard installerObserver == nil else { return }
        installerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.installer" else { return }
            MainActor.assumeIsolated { self?.detachInstallerMounts() }
        }
    }

    func detachInstallerMounts() {
        let mounts = installerMounts
        installerMounts.removeAll()
        guard !mounts.isEmpty else { return }
        Task.detached(priority: .utility) {
            for mount in mounts { try? mount.detach() }
        }
    }

    // MARK: Licence PDF

    private func saveLicence(_ model: PanelModel) {
        guard case .needsLicence(let licence, _) = model.state,
            licence.languages.indices.contains(model.licenceLanguage)
        else { return }
        let text = LicenceText.attributed(licence.languages[model.licenceLanguage])
        let save = NSSavePanel()
        save.allowedContentTypes = [.pdf]
        save.nameFieldStringValue = "\(model.appName) Licence.pdf"
        WindowPresence.activate()
        save.begin { response in
            guard response == .OK, let url = save.url else { return }
            MainActor.assumeIsolated {
                do {
                    try Self.pdf(of: text).write(to: url, options: .atomic)
                } catch {
                    Log.app.error("Couldn't save the licence: \(error, privacy: .public)")
                }
            }
        }
    }

    /// The licence on one tall page, A4 wide.
    private static func pdf(of text: NSAttributedString) -> Data {
        let width = pdfPageWidth
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textContainerInset = NSSize(width: pdfMargin, height: pdfMargin)
        view.textStorage?.setAttributedString(text)
        view.textColor = .black
        view.backgroundColor = .white
        view.sizeToFit()
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        let used = view.layoutManager.flatMap { manager in view.textContainer.map { manager.usedRect(for: $0) } }
        view.frame.size.height = (used?.height ?? 0) + pdfMargin * 2
        return view.dataWithPDF(inside: view.bounds)
    }

    /// A4 width in points, and its margin.
    private static let pdfPageWidth: CGFloat = 595
    private static let pdfMargin: CGFloat = 48
}

extension InstallState {
    var isLicence: Bool {
        if case .needsLicence = self { true } else { false }
    }
}
