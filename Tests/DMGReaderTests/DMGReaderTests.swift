import DMGReader
import Foundation
import Testing

/// End-to-end over the real sample DMGs: open each without mounting, walk every item and
/// compare counts with the Python survey that was checked against mounted copies.
/// Opt-in, since the samples are 7 GB and live outside git: `DROP_CORPUS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROP_CORPUS"] == "1"))
struct CorpusTests {
    struct Row: Decodable {
        struct FileSystem: Decodable {
            struct Stats: Decodable {
                let files: Int
                let symlinks: Int
            }
            let stats: Stats?
        }
        let path: String
        let filesystems: [FileSystem]?
    }
    struct Expected {
        let files: Int
        let symlinks: Int
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let samples = root.appending(path: ".claude/samples")
    static let survey = root.appending(path: ".claude/research/scripts/survey.jsonl")

    static func dmgs() -> [String] {
        let walker = FileManager.default.enumerator(atPath: samples.path)
        var found: [String] = []
        while let item = walker?.nextObject() as? String {
            if item.hasSuffix(".dmg") { found.append(samples.appending(path: item).path) }
        }
        return found.sorted()
    }

    @Test(arguments: dmgs())
    func opensAndWalks(path: String) throws {
        let opened = try DMGReader.open(path: path)
        #expect(try opened.apps().count == 1, "every sample holds exactly one app")
        var files = 0
        var symlinks = 0
        try DMGReader.walk(opened.fileSystem) { _, entry in
            if entry.kind == .file { files += 1 }
            if entry.kind == .symlink { symlinks += 1 }
            #expect(!entry.isCompressed)
        }
        if let expected = try Self.expected(for: path) {
            #expect(files == expected.files, "files in \(path)")
            #expect(symlinks == expected.symlinks, "symlinks in \(path)")
        }
    }

    @Test(arguments: dmgs())
    func readsInfoPlist(path: String) throws {
        let opened = try DMGReader.open(path: path)
        let app = try #require(try opened.apps().first)
        let plist = try #require(try opened.fileSystem.lookup([app.name, "Contents", "Info.plist"]))
        let data = Data(try opened.fileSystem.contents(of: plist))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(info?["CFBundleIdentifier"] is String)
    }

    static func expected(for path: String) throws -> Expected? {
        guard let text = try? String(contentsOf: survey, encoding: .utf8) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        for line in text.split(separator: "\n") {
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)),
                URL(fileURLWithPath: row.path).lastPathComponent == name,
                let stats = row.filesystems?.first?.stats
            else { continue }
            return Expected(files: stats.files, symlinks: stats.symlinks)
        }
        return nil
    }
}
