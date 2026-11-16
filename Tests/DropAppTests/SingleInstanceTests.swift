import Foundation
import Testing

@testable import DropApp

/// The single-instance rule: installed copies at any path defer to the one already
/// running, while test builds in `.build` and demo launches stay out of it.
struct SingleInstanceTests {
    static let me: pid_t = 200
    static let installed = URL(fileURLWithPath: "/Applications/Drop.app")
    static let userInstalled = URL(fileURLWithPath: "/Users/someone/Applications/Drop.app")
    static let testBuild = URL(fileURLWithPath: "/Users/someone/drop/.build/Drop.app")

    func shouldDefer(
        _ mine: URL, exempt: Bool = false, running: [SingleInstance.RunningCopy]
    ) -> Bool {
        SingleInstance.shouldDefer(myPID: Self.me, myBundle: mine, exempt: exempt, running: running)
    }

    @Test func installedCopyAtAnotherPathWins() {
        #expect(shouldDefer(Self.installed, running: [.init(pid: 100, bundleURL: Self.userInstalled)]))
    }

    @Test func runningTestBuildDoesNotStopAnInstalledLaunch() {
        #expect(!shouldDefer(Self.installed, running: [.init(pid: 100, bundleURL: Self.testBuild)]))
    }

    @Test func testBuildLaunchIgnoresAnInstalledCopy() {
        #expect(!shouldDefer(Self.testBuild, running: [.init(pid: 100, bundleURL: Self.installed)]))
    }

    @Test func samePathDefers() {
        #expect(shouldDefer(Self.installed, running: [.init(pid: 100, bundleURL: Self.installed)]))
        #expect(shouldDefer(Self.testBuild, running: [.init(pid: 100, bundleURL: Self.testBuild)]))
    }

    @Test func demoAndTestFolderLaunchesNeverDefer() {
        #expect(
            !shouldDefer(
                Self.installed, exempt: true,
                running: [
                    .init(pid: 100, bundleURL: Self.installed),
                    .init(pid: 101, bundleURL: Self.userInstalled),
                ]))
    }

    @Test func ownProcessAndBundlelessCopiesDoNotCount() {
        #expect(
            !shouldDefer(
                Self.installed,
                running: [.init(pid: Self.me, bundleURL: Self.installed), .init(pid: 100, bundleURL: nil)]))
    }

    @Test func nothingElseRunning() {
        #expect(!shouldDefer(Self.installed, running: []))
    }
}
