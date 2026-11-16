import Darwin
import Foundation
import Security

/// The `spctl --assess` fallback for `Verifier.assess`.
///
/// `spctl` asks the same syspolicyd through the same API, so it gives the same verdict and
/// source; it is a separate process with a public, documented command line, so it keeps
/// working if the header-less `SecAssessment` symbols leave Security.framework.
///
/// Cost: about the same as the framework call. Measured 2026-11-16 with `DROP_TIMING=1`
/// (`TimingTests`, online, two runs, 11 real apps): framework 71–1570 ms, `spctl` 72–1838 ms,
/// typically within 5 ms of each other on the same app (Rectangle 74–82 vs 77–86 ms, Zed
/// 394–399 vs 392–401 ms). The process launch is a few ms; the rest is syspolicyd
/// re-validating the signature, which both paths wait on. Big apps (Slack, Firefox) vary
/// by a few hundred ms run to run on either path.
enum Spctl {
    static let arguments = ["--assess", "--type", "execute", "--verbose=4"]

    /// The OSStatus block Code Signing errors live in (`errSecCSUnimplemented` -67072 to
    /// `errSecCSDetachedCertificates` -66985 in the macOS 27.2 SDK), padded for codes Apple adds.
    static let codeSigningStatuses: ClosedRange<OSStatus> = -67199...(-66900)

    /// Runs `tool` (spctl, or a stand-in in tests) on `app` and parses what it prints.
    /// Nil when it can't be launched, was killed, or printed something unrecognised.
    static func assess(_ app: URL, tool: URL, child: SpctlChild) -> Assessment? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments + [app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? child.launch(process)) == true else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else { return nil }
        return parse(String(decoding: data, as: UTF8.self), path: app.path, exitStatus: process.terminationStatus)
    }

    /// Exit statuses `spctl --assess` uses.
    enum ExitStatus {
        static let accepted: Int32 = 0
        /// The assessment itself failed (damaged code, or an error); the line holds the message.
        static let failed: Int32 = 1
        static let rejected: Int32 = 3
    }

    /// Parses `spctl --assess --verbose=4` output, which looks like:
    ///
    ///     /path/X.app: accepted                       (exit 0)
    ///     source=Notarized Developer ID
    ///
    ///     /path/X.app: rejected                       (exit 3; "source=" may follow)
    ///     /path/X.app: rejected (<error message>)     (exit 3)
    ///     /path/X.app: a sealed resource is missing or invalid   (exit 1)
    ///
    /// The error messages are `SecCopyErrorMessageString` of a Code Signing status, which
    /// `status(forMessage:)` maps back. A failure whose message isn't one gives nil, so the
    /// caller reports the assessment as unavailable rather than inventing a rejection.
    static func parse(_ output: String, path: String, exitStatus: Int32) -> Assessment? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let prefix = path + ": "
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let verdict = String(line.dropFirst(prefix.count))
        let sourcePrefix = "source="
        let source = lines.first { $0.hasPrefix(sourcePrefix) }.map { String($0.dropFirst(sourcePrefix.count)) }
        switch exitStatus {
        case ExitStatus.accepted where verdict == "accepted":
            return Assessment(accepted: true, source: source, status: nil, method: .spctl)
        case ExitStatus.rejected where verdict == "rejected":
            return Assessment(accepted: false, source: source, status: nil, method: .spctl)
        case ExitStatus.rejected where verdict.hasPrefix("rejected (") && verdict.hasSuffix(")"):
            let reason = String(verdict.dropFirst("rejected (".count).dropLast())
            return Assessment(accepted: false, source: source, status: status(forMessage: reason), method: .spctl)
        case ExitStatus.failed:
            guard let status = status(forMessage: verdict) else { return nil }
            return Assessment(accepted: false, source: source, status: status, method: .spctl)
        default:
            return nil
        }
    }

    /// Every Code Signing status by its message, for reading `spctl`'s text back as a status.
    /// The child inherits this process's locale, so its messages match these.
    private static let statusesByMessage: [String: OSStatus] = {
        var table: [String: OSStatus] = [:]
        for status in codeSigningStatuses {
            guard let message = SecCopyErrorMessageString(status, nil) as String?,
                !message.hasPrefix("OSStatus ")
            else { continue }
            if table[message] == nil { table[message] = status }
        }
        return table
    }()

    static func status(forMessage message: String) -> OSStatus? { statusesByMessage[message] }
}

/// The `spctl` child of one `assess` call, so a timeout or cancellation can kill it.
final class SpctlChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    /// Starts `process` unless `stop` already ran. Returns whether it started.
    func launch(_ process: Process) throws -> Bool {
        try lock.withLock {
            if stopped { return false }
            try process.run()
            self.process = process
            return true
        }
    }

    /// Kills the child by its PID with SIGKILL (spctl keeps no state worth a clean exit),
    /// and stops a later `launch`. Signals only while `Process` still reports the child
    /// running, so the PID is the child's own and not yet reaped (the same window
    /// `Process.terminate()` has).
    @Sendable func stop() {
        lock.withLock {
            stopped = true
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
