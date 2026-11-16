#if DEBUG
    import AppKit
    import DiskImage
    import Installer
    import Onboarding
    import SwiftUI
    import Verifier

    /// `--demo <state>`: shows one board with the boards' sample data (Linea, Tinkerpad,
    /// Vaultr, Ledgerly), no real DMG, so every state can be screenshotted. Debug builds
    /// only. Prints `DEMO_WINDOW <id>` for `screencapture -l`.
    ///
    /// States: reading, main, preparing, waiting, installing, done, update, update-running,
    /// warning, unsigned, refused, pkg, case, wontattach, licence, licence-one, password,
    /// password-wrong, settings,
    /// settings-mid and settings-bottom (the page scrolled there), settings-reopen
    /// (closed and opened again), done-long (a
    /// 30-character app name), window (the install window an opened image gets) and its
    /// states window-licence, window-licence-one, window-installing, window-done,
    /// window-warning, window-refused and window-update, and onboarding
    /// pages onboarding-1 to onboarding-5 and onboarding-2-denied (fakes, so no request
    /// reaches macOS; closing the window quits). `select-settings`, `select-main` (the
    /// popup) and `select-window` open that surface's Install to menu, plain, with `-hover`
    /// (the pointer's highlight on the second row) or `-key` (Down pressed once); they also
    /// print `DEMO_MENU <id>` and both frames for measuring.
    @MainActor
    enum Demo {
        static let states = [
            "reading", "main", "identified", "preparing", "waiting", "installing", "done", "update", "update-running",
            "warning",
            "unsigned", "refused", "pkg", "case", "wontattach", "licence", "licence-one", "password", "password-wrong",
            "progress-30", "progress-62", "settings", "settings-mid",
            "settings-bottom", "settings-reopen", "done-long", "window", "window-licence",
            "window-licence-one",
            "window-installing", "window-progress-30", "window-progress-62", "window-done", "window-warning",
            "window-refused", "window-update", "onboarding-1",
            "onboarding-2", "onboarding-2-denied", "onboarding-3",
            "onboarding-4", "onboarding-5", "select-settings", "select-settings-hover", "select-settings-key",
            "select-main", "select-main-hover", "select-window", "select-window-key",
        ]

        private static let lineaBlue = Color(red: 0x2F / 255, green: 0x6F / 255, blue: 0xEB / 255)
        private static let tinkerPurple = Color(red: 0x8E / 255, green: 0x5B / 255, blue: 0xD8 / 255)
        private static let megabyte: UInt64 = 1_000_000

        private static var linea: AppSummary {
            AppSummary(
                bundleName: "Linea.app", name: "Linea", version: "2.4.1", bundleIdentifier: "com.example.linea",
                size: 84 * megabyte, signer: "Linea Software Ltd", teamID: "ABCDE12345", isNotarized: true)
        }

        static func run(_ state: String, app: AppDelegate) {
            if state.hasPrefix("select-") {
                runSelect(state, app: app)
                return
            }
            if state.hasPrefix("onboarding-") {
                runOnboarding(state, app: app)
                return
            }
            if state.hasPrefix("settings") {
                app.settings.show()
                let scroll: SettingsWindowController.DemoScroll? =
                    switch state {
                    case "settings-mid": .middle
                    case "settings-bottom": .bottom
                    default: nil
                    }
                if scroll != nil || state == "settings-reopen" {
                    Task {
                        try? await Task.sleep(for: settle)
                        if let scroll { app.settings.demoScroll(scroll) } else { app.settings.demoReopen() }
                        try? await Task.sleep(for: redraw)
                        print("DEMO_TITLEBAR \(app.settings.titleBarHeight)")
                        report(app.settings.windowNumber ?? 0)
                    }
                    return
                }
                print("DEMO_TITLEBAR \(app.settings.titleBarHeight)")
                report(app.settings.windowNumber ?? 0)
                return
            }
            let model = makeModel(state)
            model.send = { action in
                if action == .close || action == .notNow { NSApp.terminate(nil) }
            }
            Task {
                app.panel.show(model)
                // Report once the slide-in and the content's blur have settled.
                try? await Task.sleep(for: settle)
                report(app.panel.windowNumber)
            }
        }

        /// Opens a surface's Install to select through `SelectDemo`, never a click.
        private static func runSelect(_ state: String, app: AppDelegate) {
            let parts = state.split(separator: "-").map(String.init)
            let surface = parts.count > 1 ? parts[1] : "settings"
            let mode = parts.count > 2 ? parts[2] : ""
            let label: String
            let window: () -> Int
            switch surface {
            case "main", "window":
                label = "Install to"
                let model = makeModel(surface)
                model.send = { action in
                    if action == .close || action == .notNow { NSApp.terminate(nil) }
                }
                app.panel.show(model)
                window = { app.panel.windowNumber }
            default:
                label = "Install apps to"
                app.settings.show()
                window = { app.settings.windowNumber ?? 0 }
            }
            Task {
                try? await Task.sleep(for: settle)
                guard let menu = SelectDemo.openers[label]?(mode == "key") else {
                    print("DEMO_ERROR no select named \(label)")
                    report(window())
                    return
                }
                switch mode {
                case "hover": menu.hover(1)
                case "key": menu.handle(.down)
                default: break
                }
                try? await Task.sleep(for: redraw)
                let frame = { (rect: NSRect) in "\(rect.minX) \(rect.minY) \(rect.width) \(rect.height)" }
                print("DEMO_SELECT_FRAME \(frame(menu.selectFrame))")
                print("DEMO_MENU_FRAME \(frame(menu.menuFrame))")
                print("DEMO_MENU \(menu.windowNumber)")
                report(window())
            }
        }

        /// An onboarding page on its own defaults domain with fakes for every request.
        private static func runOnboarding(_ state: String, app: AppDelegate) {
            let parts = state.split(separator: "-")
            guard parts.count >= 2, let number = Int(parts[1]), let page = OnboardingPage(rawValue: number) else {
                return
            }
            let defaults = UserDefaults(suiteName: demoSuite) ?? .standard
            OnboardingCoordinator.reset(in: defaults)
            let coordinator = OnboardingCoordinator(
                defaults: defaults, folderAccess: DeniedFolderAccess(), defaultHandler: TestDefaultHandler(),
                loginItem: TestLoginItem())
            coordinator.onEnd = { NSApp.terminate(nil) }
            app.showOnboarding(coordinator)
            Task {
                if state.hasSuffix("-denied") {
                    coordinator.preview(.downloads)
                    await coordinator.allowFolder(URL(filePath: "/Users/Shared/Downloads"))
                } else {
                    coordinator.preview(page)
                }
                try? await Task.sleep(for: settle)
                report(app.onboardingWindow?.windowNumber ?? 0)
            }
        }

        /// Long enough for the popup's spring and the staged reveals to finish.
        private static let settle: Duration = .milliseconds(2600)

        /// Long enough for a scrolled or reopened window to draw before it's captured.
        private static let redraw: Duration = .milliseconds(400)

        /// Demo onboarding never reads or writes the test domain's state.
        private static let demoSuite = "dev.niduslabs.drop.demo"

        private static func report(_ window: Int) {
            print("DEMO_WINDOW \(window)")
            fflush(stdout)
        }

        static func makeModel(_ requested: String) -> PanelModel {
            let opened = requested.hasPrefix("window")
            let state = opened ? String(requested.dropFirst("window-".count)) : requested
            let image: String
            switch state {
            case "warning", "unsigned": image = "Tinkerpad-0.9.dmg"
            case "pkg", "case", "wontattach": image = "Vaultr-Setup.dmg"
            case "password", "password-wrong": image = "Ledgerly-Pro.dmg"
            default: image = "Linea-2.4.1.dmg"
            }
            let model = PanelModel(
                dmg: URL(filePath: "/Users/Shared/Downloads/\(image)"),
                origin: opened ? .opened : .watched(folderName: "Downloads"), location: .applications,
                trashImage: true)
            model.iconOverride = .tile(lineaBlue, symbol: "line.diagonal")
            var linea = linea
            switch state {
            case "reading":
                model.iconOverride = nil
            case "identified":
                var early = linea
                early.size = nil
                early.signer = nil
                early.isNotarized = false
                model.state = .identified(early)
            case "preparing":
                var early = linea
                early.signer = nil
                early.isNotarized = false
                model.state = .preparing(early, InstallProgress(bytesDone: 30 * megabyte, bytesTotal: 84 * megabyte))
            case "waiting":
                model.state = .waitingToPrepare(linea)
            case "installing":
                model.state = .installing(linea, InstallProgress(bytesDone: 44 * megabyte, bytesTotal: 84 * megabyte))
            case "progress-30", "progress-62":
                let percent: UInt64 = state == "progress-30" ? 30 : 62
                model.state = .installing(
                    linea, InstallProgress(bytesDone: 84 * megabyte * percent / 100, bytesTotal: 84 * megabyte))
            case "done-long":
                linea = AppSummary(
                    bundleName: "Extraordinarily Long App Name.app", name: "Extraordinarily Long App Name",
                    version: "12.10.3", bundleIdentifier: "com.example.long", size: 84 * megabyte)
                model.state = .ready(linea)
                model.state = .installed(URL(filePath: "/Applications/Extraordinarily Long App Name.app"))
                model.trashedImage = URL(filePath: "/Users/Shared/.Trash/\(image)")
            case "done":
                model.state = .ready(linea)
                model.state = .installed(URL(filePath: "/Applications/Linea.app"))
                model.trashedImage = URL(filePath: "/Users/Shared/.Trash/\(image)")
                model.installDuration = .milliseconds(1200)
            case "update", "update-running":
                linea.update = .init(installedVersion: "2.3.0", developer: .same(teamID: "ABCDE12345"))
                model.state = .ready(linea)
                model.appIsRunning = state == "update-running"
            case "warning", "unsigned":
                model.iconOverride = .tile(tinkerPurple, symbol: "doc.text")
                let tinkerpad = AppSummary(
                    bundleName: "Tinkerpad.app", name: "Tinkerpad", version: "0.9",
                    bundleIdentifier: "com.example.tinkerpad", size: 22 * megabyte, signer: "Tinker Labs")
                model.state = .warning(tinkerpad, state == "warning" ? .notNotarized : .unsigned)
            case "refused":
                model.state = .refused(
                    linea, .damaged(reason: "a sealed resource is missing", status: -67_054, path: nil))
            case "pkg":
                model.iconOverride = nil
                model.state = .cannotInstall(.packageOnly(names: ["Vaultr.pkg"]))
            case "case":
                model.iconOverride = nil
                model.state = .cannotInstall(
                    .nameCollision(paths: ["Vaultr.app/Contents/README", "Vaultr.app/Contents/readme"]))
            case "wontattach":
                model.iconOverride = nil
                model.state = .cannotInstall(.wontAttach("hdiutil: attach failed"))
            case "licence", "licence-one":
                model.state = .needsLicence(
                    licence(several: state == "licence"),
                    preview: AppPreview(name: "Linea", version: "2.4.1", size: 84 * megabyte, iconData: nil))
            case "password", "password-wrong":
                model.iconOverride = nil
                model.password = "hunter22"
                model.state = .needsPassword(attempt: state == "password" ? 1 : 2)
            default:
                model.state = .ready(linea)
            }
            return model
        }

        private static func licence(several: Bool) -> LicenceAgreement {
            let text = """
                Linea Software Licence Agreement

                Please read this licence carefully before installing Linea. By clicking Agree and Install you \
                accept its terms.

                1. Licence. Linea Software Ltd grants you a personal, non-exclusive licence to use Linea on any \
                Mac you own or control.

                2. Restrictions. You may not sell, rent or sublicense Linea, or remove its notices.

                3. No warranty. Linea is provided as is, without warranty of any kind.
                """
            let english = LicenceAgreement.Language(
                regionCode: 0, resourceID: 5000, isMultiByte: false,
                body: .plain(bytes: Array(text.utf8), text: text), buttons: ["English"])
            guard several else { return LicenceAgreement(defaultLanguageIndex: 0, languages: [english]) }
            let german = LicenceAgreement.Language(
                regionCode: 3, resourceID: 5001, isMultiByte: false,
                body: .plain(bytes: [], text: "Linea Softwarelizenzvertrag"), buttons: ["Deutsch"])
            let japanese = LicenceAgreement.Language(
                regionCode: 14, resourceID: 5002, isMultiByte: true,
                body: .plain(bytes: [], text: "Linea ソフトウェア使用許諾契約"), buttons: ["日本語"])
            return LicenceAgreement(defaultLanguageIndex: 0, languages: [english, german, japanese])
        }
    }
#endif
