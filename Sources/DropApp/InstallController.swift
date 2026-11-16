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

    init(preferences: Preferences, store: Store, launch: LaunchOptions, panel: PanelWindowController) {
        self.preferences = preferences
        self.store = store
        self.launch = launch
        self.panel = panel
        panel.onDismiss = { [weak self] model in self?.handle(Self.dismissAction(for: model.board), for: model) }
    }

    /// What Esc and the window's close button mean on each board.
    private static func dismissAction(for board: Board) -> PanelAction {
        switch board {
        case .done, .refused: .close
        case .installing: .cancelInstall
        case .licence: .disagreeLicence
        default: .notNow
        }
    }

    /// The destination folder: `--destination` in tests, else the chosen location.
    private func destination(for location: InstallLocation) -> URL { launch.destination ?? location.url }

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
        if let destination = launch.destination { model.destinationName = destination.lastPathComponent }
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
        let destination = destination(for: model.location)
        if model.location == .homeApplications, launch.destination == nil {
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let trashFolder = launch.trashFolder
        let options = InstallOptions(
            destination: destination, stagingPriority: model.origin == .opened ? .userInitiated : .background,
            skipFirstLaunchPrompt: preferences.skipFirstOpenPrompt,
            trash: { url in _ = try Self.trash(url, into: trashFolder) },
            mountFallback: { dmg, reason in
                Log.app.info("Hidden mount for \(dmg.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            })
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
        guard model === current else { return }
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
        case .notNow, .disagreeLicence, .cancelInstall: dismiss(model)
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
        case .changeLocation(let location): changeLocation(model, to: location)
        }
    }

    private func install(_ model: PanelModel) {
        guard let session, !model.isBusy else { return }
        model.isBusy = true
        Task {
            var reopen = false
            if let summary = model.summary, summary.update != nil, let bundleID = summary.bundleIdentifier,
                let running = runningCopy(bundleID: bundleID, bundleName: summary.bundleName, model: model)
            {
                guard await Self.quit(running) else {
                    model.quitFailed = true
                    model.isBusy = false
                    return
                }
                reopen = true
            }
            model.reopenAfterInstall = reopen
            model.isBusy = false
            await session.install()
        }
    }

    /// Asks the app to quit, as the Quit menu item would, and waits. Never forces: an app
    /// with unsaved work may ask the user, and the user may say no.
    private static func quit(_ app: NSRunningApplication) async -> Bool {
        guard app.terminate() else { return app.isTerminated }
        let deadline = ContinuousClock.now + Theme.Timing.quitTimeout
        while !app.isTerminated, ContinuousClock.now < deadline {
            try? await Task.sleep(for: quitCheckInterval)
        }
        return app.isTerminated
    }

    /// How often Quit and Update looks whether the app has gone, while it waits.
    private static let quitCheckInterval: Duration = .milliseconds(200)

    private func installed(_ app: URL, model: PanelModel, session: InstallSession) {
        model.installedApp = app
        if case .watched = model.origin { store.markHandled(model.dmg) }
        if preferences.openAfterInstall || model.reopenAfterInstall { NSWorkspace.shared.open(app) }
        let trashFolder = launch.trashFolder
        Task {
            if model.trashImage {
                await session.waitUntilDone()
                do {
                    model.trashedImage = try Self.trash(model.dmg, into: trashFolder)
                } catch {
                    Log.app.error("Couldn't trash the disk image: \(error, privacy: .public)")
                }
            }
            // The popup closes by itself after a while; the window the user opened never does.
            if case .watched = model.origin { scheduleAutoClose(model) }
        }
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

    private func changeLocation(_ model: PanelModel, to location: InstallLocation) {
        guard location != model.location, let old = session else { return }
        model.location = location
        if launch.destination == nil { model.destinationName = location.shortName }
        session = nil
        updatesTask?.cancel()
        Task {
            await old.cancel()
            guard current === model else { return }
            startSession(for: model)
        }
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
