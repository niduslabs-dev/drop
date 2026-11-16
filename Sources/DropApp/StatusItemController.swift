import AppKit

/// The menu bar icon. By default it exists only while Drop asks something: it appears
/// when a DMG arrives, the panel anchors under it, and it leaves `Theme.Timing.iconLinger`
/// after the last panel closes. "Keep in menu bar" keeps it, with the MenuBar board's menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct MenuContent {
        var isWatching: Bool
        var folderName: String
        var recent: [RecentInstall]
    }

    var keep: Bool {
        didSet { keep ? show() : hideIfIdle() }
    }
    /// True while a panel is up: the icon must stay.
    var isBusy = false {
        didSet { if isBusy { show() } else { scheduleHide() } }
    }

    var menuContent: () -> MenuContent = { MenuContent(isWatching: true, folderName: "Downloads", recent: []) }
    var onInstallFromImage: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var onSettings: () -> Void = {}
    var onOpenRecent: (RecentInstall) -> Void = { _ in }

    private var item: NSStatusItem?
    private var hideTask: Task<Void, Never>?

    init(keep: Bool) {
        self.keep = keep
        super.init()
        if keep { show() }
    }

    func show() {
        hideTask?.cancel()
        hideTask = nil
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "drop", accessibilityDescription: "Drop")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("Drop")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    /// The icon's frame on screen, or nil when there's nothing visible to anchor to: no
    /// item, hidden by the user or behind the notch, or a full-screen app hid the menu bar.
    var anchorFrame: NSRect? {
        guard let item, item.isVisible, let button = item.button, let window = button.window else { return nil }
        guard window.occlusionState.contains(.visible) else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 0, NSScreen.screens.contains(where: { $0.frame.contains(frame) }) else { return nil }
        return frame
    }

    /// For the demo: opens the menu as if clicked.
    func openMenu() { item?.button?.performClick(nil) }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Theme.Timing.iconLinger)
            guard !Task.isCancelled else { return }
            self?.hideIfIdle()
        }
    }

    private func hideIfIdle() {
        guard !keep, !isBusy, let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let content = menuContent()

        let status = NSMenuItem(
            title: content.isWatching ? "Watching \(content.folderName)" : "Paused", action: nil, keyEquivalent: "")
        status.image = Self.dot(content.isWatching ? .systemGreen : .tertiaryLabelColor)
        status.isEnabled = false
        menu.addItem(status)

        if !content.recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recently installed"))
            let now = Date.now
            for recent in content.recent.prefix(Self.recentInMenu) {
                let row = NSMenuItem(title: recent.title, action: #selector(openRecent(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = recent.path
                row.attributedTitle = Self.titleWithTime(recent.title, Format.relative(recent.date, now: now))
                let icon = NSWorkspace.shared.icon(forFile: recent.path)
                icon.size = NSSize(width: Theme.Icon.menuSize, height: Theme.Icon.menuSize)
                row.image = icon
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Install from Disk Image…", #selector(installFromImage), key: "o"))
        menu.addItem(item(content.isWatching ? "Pause Watching" : "Resume Watching", #selector(togglePause), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(settings), key: ","))
        menu.addItem(item("Quit Drop", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    static let recentInMenu = 5

    private func item(_ title: String, _ action: Selector, key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    /// The name, then the time right-aligned, as on the MenuBar board.
    private static func titleWithTime(_ title: String, _ time: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: menuTimeColumn)]
        let text = NSMutableAttributedString(
            string: "\(title)\t", attributes: [.font: font, .paragraphStyle: style])
        text.append(
            NSAttributedString(
                string: time,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
                ]))
        return text
    }

    /// Where the right-aligned time ends in a Recently installed row (the board's menu is
    /// 280 pt wide).
    private static let menuTimeColumn: CGFloat = 210

    private static func dot(_ colour: NSColor) -> NSImage {
        let size = NSSize(width: Theme.MenuBar.statusDot, height: Theme.MenuBar.statusDot)
        return NSImage(size: size, flipped: false) { rect in
            colour.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    @objc private func installFromImage() { onInstallFromImage() }
    @objc private func togglePause() { onTogglePause() }
    @objc private func settings() { onSettings() }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
            let recent = menuContent().recent.first(where: { $0.path == path })
        else { return }
        onOpenRecent(recent)
    }
}
