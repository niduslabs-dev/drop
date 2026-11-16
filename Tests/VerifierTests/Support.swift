import Foundation
import Testing

@testable import Verifier

/// Where `scripts/fixtures-verifier.sh` puts its output.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/fixtures/verifier")
    static let missing = "Verifier fixtures missing: run scripts/fixtures-verifier.sh from the package root first"

    /// Notarized apps copied out of real DMGs. Never launched.
    static let notarized = [
        "Rectangle", "KeePassXC", "Stats", "MonitorControl", "Clipy", "Slack", "Firefox", "Zed", "Transmission", "VLC",
    ]
    /// Signed with an Apple Development certificate: valid, not notarized.
    static let developmentSigned = "boringNotch"
    /// DMG stapled, app not: the case Drop staples.
    static let dmgOnlyTicket = ["Rectangle", "KeePassXC", "Zed", "Transmission", "VLC"]

    static func real(_ name: String) throws -> URL {
        let url = root.appending(path: "real/\(name).app")
        try #require(FileManager.default.fileExists(atPath: url.path), "\(missing) (\(name))")
        return url
    }

    static func dmg(_ name: String) throws -> String {
        let url = root.appending(path: "real/\(name).dmg")
        try #require(FileManager.default.fileExists(atPath: url.path), "\(missing) (\(name).dmg)")
        return url.resolvingSymlinksInPath().path
    }

    static func synthetic(_ name: String) throws -> URL {
        let url = root.appending(path: "synthetic/\(name).app")
        try #require(FileManager.default.fileExists(atPath: url.path), "\(missing) (\(name))")
        return url
    }

    /// The `TeamIdentifier=` line of the `codesign -dv` output the script saved.
    static func codesignTeamID(_ name: String) throws -> String? {
        let text = try String(contentsOf: root.appending(path: "real/\(name).codesign"), encoding: .utf8)
        return text.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    /// A fresh copy of `app` in a new folder under the fixtures, removed by the caller.
    static func copy(_ app: URL) throws -> (app: URL, folder: URL) {
        let folder = root.appending(path: "work/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: app.lastPathComponent)
        let result = try run("/usr/bin/ditto", [app.path, destination.path])
        try #require(result.status == 0, "ditto: \(result.output)")
        return (destination, folder)
    }

    /// Runs a tool (never one of the fixture apps) and returns its status and output.
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
