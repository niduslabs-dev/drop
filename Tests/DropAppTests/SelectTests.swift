import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import DropApp

/// The Nidus select's option model, keyboard rules and path display.
struct SelectTests {
    private static let names = [
        SelectMenuRow.typeaheadNames(label: "/Applications", keywords: ["Applications"]),
        SelectMenuRow.typeaheadNames(label: "~/Applications", keywords: ["Applications in your home folder"]),
    ]

    // MARK: Option model

    @Test func typeaheadNamesDropThePathPrefixAndLowercase() {
        #expect(Self.names[0] == ["/applications", "applications", "applications"])
        #expect(Self.names[1] == ["~/applications", "applications", "applications in your home folder"])
    }

    @Test func opensWithTheSelectedRowHighlighted() {
        let state = SelectMenuState(names: Self.names, selected: 1)
        #expect(state.selected == 1)
        #expect(state.highlighted == 1)
    }

    @Test func openedWithThePointerNothingIsHighlightedAndDownStartsAtTheSelection() {
        var state = SelectMenuState(names: Self.names, selected: 1, highlightsSelected: false)
        #expect(state.highlighted == nil)
        #expect(state.handle(.down, at: 0) == .highlighted(1))
    }

    @Test func anOutOfRangeSelectionHighlightsNothing() {
        let state = SelectMenuState(names: Self.names, selected: 5)
        #expect(state.selected == nil)
        #expect(state.highlighted == nil)
    }

    @Test func hoverFollowsThePointerAndClearsOffTheRows() {
        var state = SelectMenuState(names: Self.names, selected: 0)
        state.hover(1)
        #expect(state.highlighted == 1)
        state.hover(nil)
        #expect(state.highlighted == nil)
        state.hover(7)
        #expect(state.highlighted == nil)
    }

    // MARK: Keyboard

    @Test func arrowsMoveAndStopAtTheEnds() {
        var state = SelectMenuState(names: Self.names, selected: 0)
        #expect(state.handle(.down, at: 0) == .highlighted(1))
        #expect(state.handle(.down, at: 0) == .highlighted(1))
        #expect(state.handle(.up, at: 0) == .highlighted(0))
        #expect(state.handle(.up, at: 0) == .highlighted(0))
        #expect(state.handle(.end, at: 0) == .highlighted(1))
        #expect(state.handle(.home, at: 0) == .highlighted(0))
    }

    @Test func arrowsFromNoHighlightStartAtAnEnd() {
        var down = SelectMenuState(names: Self.names, selected: nil)
        #expect(down.handle(.down, at: 0) == .highlighted(0))
        var up = SelectMenuState(names: Self.names, selected: nil)
        #expect(up.handle(.up, at: 0) == .highlighted(1))
    }

    @Test func returnAndSpaceChooseTheHighlightedRow() {
        var state = SelectMenuState(names: Self.names, selected: 0)
        _ = state.handle(.down, at: 0)
        #expect(state.handle(.confirm, at: 0) == .choose(1))
        #expect(state.handle(.space, at: 0) == .choose(1))
        state.hover(nil)
        #expect(state.handle(.confirm, at: 0) == .close)
    }

    @Test func escapeClosesAndTabClosesAndPasses() {
        var state = SelectMenuState(names: Self.names, selected: 0)
        #expect(state.handle(.escape, at: 0) == .close)
        #expect(state.handle(.tab, at: 0) == .closeAndPass)
    }

    @Test func typeaheadFindsTheHomeFolderByItsTilde() {
        var state = SelectMenuState(names: Self.names, selected: 0)
        #expect(state.handle(.text("~"), at: 0) == .highlighted(1))
        #expect(state.handle(.text("/"), at: 5) == .highlighted(0))
    }

    @Test func aRepeatedLetterStepsThroughMatchingRows() {
        var state = SelectMenuState(names: Self.names, selected: 0)
        #expect(state.handle(.text("a"), at: 0) == .highlighted(1))
        #expect(state.handle(.text("a"), at: 5) == .highlighted(0))
    }

    @Test func typedLettersBuildOneSearchUntilAPause() {
        var state = SelectMenuState(names: Self.names, selected: 0)
        _ = state.handle(.text("a"), at: 0)
        // "applications i" only matches the home folder's name; the space is typed, not a choice.
        #expect(state.handle(.text("pplications"), at: 0.2) == .highlighted(1))
        #expect(state.handle(.space, at: 0.3) == .highlighted(1))
        #expect(state.handle(.text("i"), at: 0.4) == .highlighted(1))
        // After the pause a new search starts.
        #expect(state.handle(.text("z"), at: 3) == .ignored)
        #expect(state.highlighted == 1)
    }

    @Test func keysMapFromEvents() {
        let none: NSEvent.ModifierFlags = []
        #expect(SelectKey(keyCode: UInt16(kVK_DownArrow), characters: nil, modifiers: none) == .down)
        #expect(SelectKey(keyCode: UInt16(kVK_Return), characters: "\r", modifiers: none) == .confirm)
        #expect(SelectKey(keyCode: UInt16(kVK_ANSI_KeypadEnter), characters: "\u{3}", modifiers: none) == .confirm)
        #expect(SelectKey(keyCode: UInt16(kVK_Escape), characters: "\u{1b}", modifiers: none) == .escape)
        #expect(SelectKey(keyCode: UInt16(kVK_ANSI_A), characters: "a", modifiers: none) == .text("a"))
        #expect(SelectKey(keyCode: UInt16(kVK_ANSI_A), characters: "a", modifiers: .command) == nil)
        #expect(SelectKey(keyCode: UInt16(kVK_F5), characters: "\u{F708}", modifiers: none) == nil)
    }

    @Test func spaceReturnAndArrowsOpenAClosedSelect() {
        let opening = [SelectKey.space, .confirm, .down, .up].map(\.opensSelect)
        let others = [SelectKey.escape, .tab, .text("a"), .home].map(\.opensSelect)
        #expect(opening == [true, true, true, true])
        #expect(others == [false, false, false, false])
    }

    // MARK: Path display

    private static let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    @Test func pathsAbbreviateTheHomeFolder() {
        #expect(InstallLocation.applications.displayPath(home: Self.home) == "/Applications")
        let homeApps = Self.home.appending(path: "Applications", directoryHint: .isDirectory)
        #expect(FolderDisplay.path(homeApps, home: Self.home) == "~/Applications")
        #expect(FolderDisplay.path(Self.home, home: Self.home) == "~")
        // A sibling whose name starts like the home folder isn't inside it.
        #expect(
            FolderDisplay.path(URL(filePath: "/Users/someone2/Applications"), home: Self.home)
                == "/Users/someone2/Applications")
    }

    @Test func homeApplicationsShowsAsTildeForTheRealHome() {
        #expect(InstallLocation.homeApplications.displayPath() == "~/Applications")
    }

    @Test func accessibilityLabelsCarryTheFullPath() {
        #expect(InstallLocation.applications.accessibilityLabel == "Applications, /Applications")
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let expected = "Applications in your home folder, \(home.hasSuffix("/") ? home : home + "/")Applications"
        #expect(InstallLocation.homeApplications.accessibilityLabel == expected)
    }

    @Test func iconFallsBackToTheSystemApplicationsFolder() {
        let homeApps = Self.home.appending(path: "Applications", directoryHint: .isDirectory)
        let other = Self.home.appending(path: "Tools", directoryHint: .isDirectory)
        let everything: (String) -> Bool = { _ in true }
        let systemOnly: (String) -> Bool = { $0 == "/Applications" }
        let nothing: (String) -> Bool = { _ in false }
        let found = FolderDisplay.iconPath(for: homeApps, exists: everything)
        let fallback = FolderDisplay.iconPath(for: homeApps, exists: systemOnly)
        let generic = FolderDisplay.iconPath(for: homeApps, exists: nothing)
        let unrelated = FolderDisplay.iconPath(for: other, exists: systemOnly)
        #expect(found == "/Users/someone/Applications")
        #expect(fallback == "/Applications")
        #expect(generic == nil)
        #expect(unrelated == nil)
    }
}
