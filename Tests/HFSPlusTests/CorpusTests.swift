import Foundation
import ReaderCore
import Testing

@testable import HFSPlus

/// Real app DMGs converted to raw images by the fixture script. Opt in with `DROP_CORPUS=1`.
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
        let device = try FileDevice(path: try Fixtures.path("corpus/\(name).cdr"))
        return try HFSPlusVolume(device: try hfsPartition(device))
    }
}

/// Finds the HFS+ partition of a raw whole-disk image: GPT entries, then APM entries,
/// then offset 0, taking the first whose volume header signature is `H+` or `HX`.
func hfsPartition(_ disk: any BlockDevice) throws -> any BlockDevice {
    let sector: UInt64 = 512
    var candidates: [(start: UInt64, size: UInt64)] = []
    let gpt = ByteReader(try disk.read(at: sector, count: Int(sector)))
    if try gpt.slice(0, 8) == Array("EFI PART".utf8) {
        let entriesLBA = try gpt.le64(72)
        let count = min(try gpt.le32(80), 128)
        let entrySize = UInt64(try gpt.le32(84))
        for index in 0..<UInt64(count) {
            let entry = ByteReader(try disk.read(at: entriesLBA * sector + index * entrySize, count: 128))
            let first = try entry.le64(32)
            let last = try entry.le64(40)
            if first > 0, last >= first { candidates.append((first * sector, (last - first + 1) * sector)) }
        }
    }
    let ddm = ByteReader(try disk.read(at: 0, count: Int(sector)))
    if try ddm.slice(0, 2) == Array("ER".utf8) {
        let block = UInt64(try ddm.be16(2))
        let first = ByteReader(try disk.read(at: block, count: Int(sector)))
        let count = min(try first.be32(4), 64)
        for index in 1...UInt64(count) {
            let entry = ByteReader(try disk.read(at: index * block, count: Int(sector)))
            guard try entry.slice(0, 2) == Array("PM".utf8) else { continue }
            candidates.append((UInt64(try entry.be32(8)) * block, UInt64(try entry.be32(12)) * block))
        }
    }
    candidates.append((0, disk.size))
    for (start, size) in candidates where start + size <= disk.size && size > 2048 {
        let signature = try disk.read(at: start + 1024, count: 2)
        if signature == Array("H+".utf8) || signature == Array("HX".utf8) {
            return try SliceDevice(base: disk, start: start, size: size)
        }
    }
    throw ReaderError.unsupportedFileSystem("no HFS+ partition")
}
