import DiskImage
import Foundation
import ReaderCore
import Testing

@testable import HFSPlus

/// Real app DMGs from `.claude/samples/`, opened directly through `DiskImage`. Opt in with `DROP_CORPUS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROP_CORPUS"] == "1"))
struct CorpusTests {
    /// Catalog record counts from `.claude/research/scripts/survey.jsonl` (survey.py).
    static let survey: [String: HFSPlusVolume.Statistics] = [
        "rectangle": .init(folders: 120, files: 157, symlinks: 7),
        "slack": .init(folders: 346, files: 355, symlinks: 15),
        "firefox": .init(folders: 55, files: 113, symlinks: 1),
    ]

    @Test(arguments: ["rectangle", "slack", "firefox"])
    func countsMatchSurvey(_ name: String) throws {
        let volume = try openCorpus(name)
        let expected = try #require(Self.survey[name])
        #expect(volume.statistics.folders == expected.folders)
        #expect(volume.statistics.files == expected.files)
        #expect(volume.statistics.symlinks == expected.symlinks)

        let entries = try walk(volume)
        let symlinks = entries.filter { $0.entry.kind == .symlink }
        for (path, link) in symlinks { #expect(!(try volume.symlinkTarget(of: link)).isEmpty, "\(path)") }
        let app = try #require(entries.first { $0.path.hasSuffix(".app/Contents/Info.plist") })
        let plist = try PropertyListSerialization.propertyList(
            from: Data(try volume.contents(of: app.entry)), format: nil)
        #expect((plist as? [String: Any])?["CFBundleShortVersionString"] != nil)
    }

    @Test func slackReadThroughput() throws {
        let volume = try openCorpus("slack")
        let clock = ContinuousClock()
        var files = 0
        var bytes = 0
        let elapsed = try clock.measure {
            for (_, entry) in try walk(volume) where entry.kind == .file && !entry.isCompressed {
                try volume.read(entry) { _, chunk in bytes += chunk.count }
                files += 1
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            String(
                format: "Slack: %d files, %.1f MB in %.3f s: %.0f files/s, %.0f MB/s", files, Double(bytes) / 1e6,
                seconds, Double(files) / seconds, Double(bytes) / 1e6 / seconds))
        #expect(files > 0)
    }

    private func openCorpus(_ name: String) throws -> HFSPlusVolume {
        let image = try DiskImage.open(path: try Fixtures.sample(name))
        return try HFSPlusVolume(device: try image.fileSystem().device)
    }
}
