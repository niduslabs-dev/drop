import Foundation
import Synchronization

/// What a finished (or stopped) child process left behind.
struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    /// The child ran past its timeout and was stopped.
    var timedOut: Bool

    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs a tool with `Process` (no shell), feeds it stdin once and closes it, and stops it
/// by its own PID if it runs past `timeout`: SIGTERM first, SIGKILL after
/// `killGraceSeconds`. stdin is always a pipe that reaches EOF, so a tool that asks a
/// question (diskutil's licence prompt) gets "no answer" instead of waiting forever.
enum BoundedProcess {
    static let killGraceSeconds = 2.0
    /// How long to wait for the output pipes to close after the child is gone. A grandchild
    /// holding them open must not hang the caller.
    static let drainSeconds = 5.0

    static func run(
        _ executable: String, _ arguments: [String], timeout: Duration,
        input: (_ write: (UnsafeRawBufferPointer) -> Void) -> Void = { _ in }
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let output = Mutex<(Data, Data)>((Data(), Data()))
        let drained = DispatchGroup()
        for (index, pipe) in [stdoutPipe, stderrPipe].enumerated() {
            drained.enter()
            let reader = pipe.fileHandleForReading
            Thread.detachNewThread {
                let data = reader.readDataToEndOfFile()
                output.withLock { if index == 0 { $0.0 = data } else { $0.1 = data } }
                drained.leave()
            }
        }

        try process.run()
        let writeFD = stdinPipe.fileHandleForWriting.fileDescriptor
        // A child that exits before reading would otherwise raise SIGPIPE in Drop.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        input { bytes in
            guard let base = bytes.baseAddress else { return }
            var done = 0
            while done < bytes.count {
                let n = write(writeFD, base + done, bytes.count - done)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return }
                done += n
            }
        }
        try? stdinPipe.fileHandleForWriting.close()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout.seconds) == .timedOut {
            timedOut = true
            let pid = process.processIdentifier
            process.terminate()
            if exited.wait(timeout: .now() + killGraceSeconds) == .timedOut {
                kill(pid, SIGKILL)
                exited.wait()
            }
        }
        _ = drained.wait(timeout: .now() + drainSeconds)
        let (out, err) = output.withLock { $0 }
        return ProcessResult(status: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
