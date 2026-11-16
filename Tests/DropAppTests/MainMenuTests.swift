import AppKit
import Testing

@testable import DropApp

/// The main menu's structure and key equivalents: without it ⌘W, ⌘Q and paste have
/// nowhere to go in an `LSUIElement` app.
@MainActor
struct MainMenuTests {
    final class Target: NSObject {
        @objc func openSettings(_ sender: Any?) {}
    }

    struct Expected: CustomStringConvertible, Sendable {
        let menu: String
        let title: String
        let action: String
        let key: String
        let modifiers: NSEvent.ModifierFlags
        var description: String { "\(menu) › \(title)" }
    }

    nonisolated static let expected: [Expected] = [
        Expected(
            menu: "Drop", title: "About Drop", action: "orderFrontStandardAboutPanel:", key: "", modifiers: .command),
        Expected(menu: "Drop", title: "Settings\u{2026}", action: "openSettings:", key: ",", modifiers: .command),
        Expected(menu: "Drop", title: "Hide Drop", action: "hide:", key: "h", modifiers: .command),
        Expected(
            menu: "Drop", title: "Hide Others", action: "hideOtherApplications:", key: "h",
            modifiers: [.command, .option]),
        Expected(menu: "Drop", title: "Quit Drop", action: "terminate:", key: "q", modifiers: .command),
        Expected(menu: "File", title: "Close Window", action: "performClose:", key: "w", modifiers: .command),
        Expected(menu: "Edit", title: "Undo", action: "undo:", key: "z", modifiers: .command),
        Expected(menu: "Edit", title: "Redo", action: "redo:", key: "z", modifiers: [.command, .shift]),
        Expected(menu: "Edit", title: "Cut", action: "cut:", key: "x", modifiers: .command),
        Expected(menu: "Edit", title: "Copy", action: "copy:", key: "c", modifiers: .command),
        Expected(menu: "Edit", title: "Paste", action: "paste:", key: "v", modifiers: .command),
        Expected(menu: "Edit", title: "Select All", action: "selectAll:", key: "a", modifiers: .command),
        Expected(menu: "Window", title: "Minimize", action: "performMiniaturize:", key: "m", modifiers: .command),
        Expected(menu: "Window", title: "Zoom", action: "performZoom:", key: "", modifiers: .command),
    ]

    @Test func hasTheFourMenusInOrder() {
        let menu = MainMenu.make(settingsTarget: nil, settingsAction: #selector(Target.openSettings(_:)))
        #expect(menu.items.map(\.title) == ["Drop", "File", "Edit", "Window"])
    }

    @Test(arguments: expected)
    func itemHasItsActionAndKey(_ expected: Expected) throws {
        let target = Target()
        let menu = MainMenu.make(settingsTarget: target, settingsAction: #selector(Target.openSettings(_:)))
        let submenu = try #require(menu.item(withTitle: expected.menu)?.submenu)
        let item = try #require(submenu.item(withTitle: expected.title))
        #expect(item.action.map(NSStringFromSelector) == expected.action)
        #expect(item.keyEquivalent == expected.key)
        if !expected.key.isEmpty { #expect(item.keyEquivalentModifierMask == expected.modifiers) }
        if expected.title == "Settings\u{2026}" {
            #expect(item.target === target)
        } else {
            #expect(item.target == nil, "acts on the key window through the responder chain")
        }
    }
}
