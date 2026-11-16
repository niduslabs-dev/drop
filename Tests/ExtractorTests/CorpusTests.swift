import DMGReader
import Foundation
import Testing

@testable import Extractor

private let corpusEnabled = ProcessInfo.processInfo.environment["DROP_CORPUS"] == "1"
private let timingEnabled = ProcessInfo.processInfo.environment["DROP_TIMING"] == "1"
private let referenceRoot = packageRoot.appendingPathComponent(".build/fixtures/reference")

/// Xattrs a ditto copy gains or loses on this Mac that say nothing about fidelity.
private let machineLocalXattrs: Set<String> = [Quarantine.attributeName, "com.apple.provenance", "com.apple.macl"]

/// FinderInfo bytes 20..<24 hold the date added, which differs between any two copies.
private let finderInfoDateAdded = 20..<24

/// The DMG and app name `scripts/reference-apps.sh` recorded for `name`.
private func reference(_ name: String) throws -> (dmg: String, app: String, copy: URL) {
    let info = referenceRoot.appendingPathComponent("\(name)/dmg.txt")
    let lines = try #require(
        try? String(contentsOf: info, encoding: .utf8).split(separator: "\n").map(String.init),
        "run scripts/reference-apps.sh first")
    try #require(lines.count == 2)
    return (lines[0], lines[1], referenceRoot.appendingPathComponent("\(name)/\(lines[1])"))
}

private func normalizedXattrs(_ xattrs: [String: [UInt8]]) -> [String: [UInt8]] {
    var out = xattrs.filter { !machineLocalXattrs.contains($0.key) }
    if var info = out["com.apple.FinderInfo"], info.count == 32 {
        info.replaceSubrange(finderInfoDateAdded, with: [0, 0, 0, 0])
        out["com.apple.FinderInfo"] = info.allSatisfy { $0 == 0 } ? nil : info
    }
    return out
}

/// Every difference between two trees, as readable lines.
func differences(reference: [BytePath: DiskItem], extracted: [BytePath: DiskItem]) -> [String] {
    var out: [String] = []
    for path in Set(reference.keys).subtracting(extracted.keys).sorted() { out.append("missing \(path)") }
    for path in Set(extracted.keys).subtracting(reference.keys).sorted() { out.append("extra \(path)") }
    var refGroups: [UInt64: Set<BytePath>] = [:]
    var extGroups: [UInt64: Set<BytePath>] = [:]
    for (path, want) in reference.sorted(by: { $0.key < $1.key }) {
        guard let got = extracted[path] else { continue }
        func check(_ what: String, _ ok: Bool) { if !ok { out.append("\(path): \(what)") } }
        check("kind", want.kind == got.kind)
        check("mode \(String(want.mode, radix: 8)) vs \(String(got.mode, radix: 8))", want.mode & 0o777 == got.mode)
        check("size", want.size == got.size)
        check("sha256", want.sha256 == got.sha256)
        check("target", want.target == got.target)
        let wantX = normalizedXattrs(want.xattrs)
        let gotX = normalizedXattrs(got.xattrs)
        check("xattr names \(wantX.keys.sorted()) vs \(gotX.keys.sorted())", Set(wantX.keys) == Set(gotX.keys))
        for (name, value) in wantX where gotX[name] != nil && gotX[name] != value {
            out.append("\(path): xattr \(name) value differs")
        }
        // ditto gives symlinks the copy's time; Drop keeps the image's, so they differ by design.
        check(
            "mtime \(want.mtime.tv_sec).\(want.mtime.tv_nsec) vs \(got.mtime.tv_sec).\(got.mtime.tv_nsec)",
            want.kind == .symlink
                || (want.mtime.tv_sec == got.mtime.tv_sec && want.mtime.tv_nsec == got.mtime.tv_nsec))
        if want.kind == .file && want.nlink > 1 { refGroups[want.inode, default: []].insert(path) }
        if got.kind == .file && got.nlink > 1 { extGroups[got.inode, default: []].insert(path) }
    }
    if Set(refGroups.values) != Set(extGroups.values) { out.append("hard link groups differ") }
    return out
}

/// `codesign --verify --deep --strict`: exit status and what it said.
private func codesignVerify(_ app: URL) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--verify", "--deep", "--strict", app.path]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

@Suite(.enabled(if: corpusEnabled, "set DROP_CORPUS=1"), .serialized)
struct CorpusFidelityTests {
    static let apps = ["rectangle", "slack", "firefox", "docker", "gimp", "zed", "spotify", "vlc"]

    @Test(arguments: apps)
    func matchesADittoCopy(_ name: String) throws {
        let (dmg, appName, copy) = try reference(name)
        let image = try DMGReader.open(path: dmg)
        let app = try #require(try image.apps().first { $0.name == appName }, "\(appName) not in \(dmg)")
        let destination = try scratchFolder("corpus-\(name)")
        let started = Date()
        let staged = try Extractor.stage(
            app: app, from: image.fileSystem, into: try Extractor.makeStagingArea(for: destination))
        let seconds = Date().timeIntervalSince(started)
        defer { discardAndWait(staged) }

        var want = try snapshot(copy)
        want[BytePath("")] = try diskItem(copy.path)
        var got = try snapshot(staged.url)
        got[BytePath("")] = try diskItem(staged.url.path)
        let problems = differences(reference: want, extracted: got)
        let (refStatus, refOutput) = try codesignVerify(copy)
        let (gotStatus, gotOutput) = try codesignVerify(staged.url)
        print(
            "corpus \(name): \(got.count) items, \(String(format: "%.2f", seconds)) s, \(problems.count) differences,"
                + " codesign reference=\(refStatus) extracted=\(gotStatus)")
        for line in problems.prefix(15) { print("  \(line)") }
        #expect(problems.isEmpty, "\(name): \(problems.count) differences, first: \(problems.prefix(10))")
        #expect(refStatus == gotStatus, "codesign: reference \(refOutput) extracted \(gotOutput)")
    }
}

@Suite(.enabled(if: timingEnabled, "set DROP_TIMING=1 and build with -c release"), .serialized)
struct TimingTests {
    /// Write-only estimates from write-bench.md (c, 4 threads, synthetic data from RAM), and
    /// the decode times from benchmarks.md (11 threads), for comparison.
    static let estimates: [String: (write: Double, decode: Double)] = [
        "gimp": (0.61, 0.06), "firefox": (0.08, 0.63), "docker": (0.48, 2.2),
    ]

    @Test(arguments: ["gimp", "firefox", "docker"])
    func stageSpeed(_ name: String) throws {
        let (dmg, appName, _) = try reference(name)
        for (label, priority) in [("userInitiated", StageOptions.Priority.userInitiated), ("background", .background)] {
            let image = try DMGReader.open(path: dmg)
            let app = try #require(try image.apps().first { $0.name == appName })
            let destination = try scratchFolder("timing-\(name)")
            let area = try Extractor.makeStagingArea(for: destination)
            let started = Date()
            let staged = try Extractor.stage(
                app: app, from: image.fileSystem, into: area, options: StageOptions(priority: priority))
            let seconds = Date().timeIntervalSince(started)
            let bytes = try snapshot(staged.url).values.reduce(UInt64(0)) { $0 + $1.size }
            let estimate = Self.estimates[name].map { "write \($0.write) s + decode \($0.decode) s" } ?? ""
            print(
                "timing \(name) \(label): \(String(format: "%.2f", seconds)) s,"
                    + " \(String(format: "%.0f", Double(bytes) / 1_000_000 / seconds)) MB/s (estimate \(estimate))")
            let done = DispatchSemaphore(value: 0)
            Extractor.discard(staged) { done.signal() }
            _ = done.wait(timeout: .now() + 60)
        }
    }
}
