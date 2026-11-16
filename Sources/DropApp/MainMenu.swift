import AppKit

/// Drop's main menu: the app, File, Edit and Window menus with the standard key equivalents.
///
/// Drop is an `LSUIElement` app, so the menu bar shows these only while Drop is a regular
/// app (Settings, the install window or onboarding is open; see `ActivationPolicy`). The key
/// equivalents work whenever a Drop window is key, which is why the menu exists at all:
/// without it ⌘W, ⌘Q and ⌘V have nowhere to go.
///
/// Every item but Settings… targets the responder chain (nil target), so it acts on the key
/// window: Close Window sends `performClose(_:)`, which closes Settings, is Not now in the
/// install window (`CentredPanelWindow`) and records the dismissal in onboarding (its
/// `windowWillClose`). The popup is a non-activating panel and is rarely key; when it is,
/// Esc is its dismiss key.
@MainActor
enum MainMenu {
    /// Builds the menu. `settingsTarget` receives `settingsAction` for Settings… (⌘,).
    static func make(appName: String = "Drop", settingsTarget: AnyObject?, settingsAction: Selector) -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenu: appMenu(appName: appName, settingsTarget: settingsTarget, settingsAction: settingsAction))
        main.addItem(submenu: fileMenu())
        main.addItem(submenu: editMenu())
        main.addItem(submenu: windowMenu())
        return main
    }

    /// Sets `NSApp.mainMenu` and `NSApp.windowsMenu`.
    static func install(settingsTarget: AnyObject?, settingsAction: Selector) {
        let menu = make(settingsTarget: settingsTarget, settingsAction: settingsAction)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.item(withTitle: "Window")?.submenu
    }

    private static func appMenu(appName: String, settingsTarget: AnyObject?, settingsAction: Selector) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(
            item(
                "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), key: ""))
        menu.addItem(.separator())
        let settings = item("Settings\u{2026}", settingsAction, key: ",")
        settings.target = settingsTarget
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(
            item(
                "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), key: ""))
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

extension NSMenu {
    /// Adds `submenu` under an item of the same title.
    fileprivate func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
