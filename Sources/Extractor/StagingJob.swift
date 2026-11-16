import Darwin
import Foundation
import Synchronization

/// A handle on one `Extractor.stage` call that lets the app raise its priority while it
/// runs. Pass it in `StageOptions.job`, then call `boost()` when the user clicks Install.
///
/// From the boost on, every worker switches itself from background to user-initiated QoS
/// (which also lifts the disk I/O throttle) before its next buffer, and `StageOptions.onBoost` runs once so the app can
/// speed up the device too (such as a UDIF device's decode policy). Boosting before
/// `stage` starts makes it start fast. Safe to call from any thread, any number of times.
public final class StagingJob: Sendable {
    private let boosted = Atomic<Bool>(false)
    /// The hook of the `stage` call using this job, until it has run.
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)
    /// Workers that switched to user-initiated QoS mid-stage and confirmed it took.
    let boostedWorkers = Atomic<Int>(0)

    private let gate = PauseGate()

    public init() {}

    /// True once `boost()` has been called.
    public var isBoosted: Bool { boosted.load(ordering: .acquiring) }

    /// Raises the job to user-initiated priority for whatever is left, and lifts a pause.
    /// Returns at once; the hook runs on this thread, the workers switch themselves.
    public func boost() {
        guard !boosted.exchange(true, ordering: .acquiringAndReleasing) else { return }
        gate.set(paused: false)
        let pending = hook.withLock { hook in
            defer { hook = nil }
            return hook
        }
        pending?()
    }

    /// Holds the stage between items (before the next folder, symlink or file; a file
    /// being written finishes first) until `resume()` or `boost()`. For Low Power Mode and
    /// thermal pressure, where the plan says background work waits for Install. Does
    /// nothing once boosted. Cancellation still ends a paused stage: call `resume()` after
    /// setting the cancel flag, or wait up to `PauseGate.cancelCheckInterval`.
    public func pause() {
        guard !isBoosted else { return }
        gate.set(paused: true)
    }

    /// Lets a paused stage go on.
    public func resume() { gate.set(paused: false) }

    /// True while paused.
    public var isPaused: Bool { gate.isPaused }

    /// Blocks the calling worker while the job is paused, or until `isCancelled` says so.
    func waitWhilePaused(isCancelled: () -> Bool) { gate.wait(isCancelled: isCancelled) }

    /// Registers `stage`'s hook. Runs it here and now when the job is already boosted.
    func attach(_ onBoost: (@Sendable () -> Void)?) {
        guard let onBoost else { return }
        let runNow = hook.withLock { hook in
            if isBoosted { return true }
            hook = onBoost
            return false
        }
        if runNow { onBoost() }
    }

    /// Drops the hook once `stage` returns, so a late boost doesn't call into a finished job.
    func detach() {
        hook.withLock { $0 = nil }
    }
}

/// A worker thread's share of a job's priority, so the switch costs one atomic load per
/// check until it happens, and one system call once.
///
/// Priority is QoS alone. Background QoS already throttles the thread's disk I/O, and
/// `setiopolicy_np` can't be used on top: a thread that calls it for itself opts out of
/// QoS for good (its QoS reads as unspecified and `pthread_set_qos_class_self_np` then
/// fails with `EPERM`, even after setting `IOPOL_DEFAULT` back; measured on macOS 27).
/// For the same reason workers set their QoS from inside rather than through
/// `Thread.qualityOfService`, which also leaves it fixed.
struct WorkerPriority {
    let job: StagingJob
    private(set) var isFast: Bool

    /// Sets the current thread's starting QoS: background, unless the job runs fast
    /// (user-initiated, or already boosted).
    init(job: StagingJob, background: Bool) {
        self.job = job
        isFast = !background || job.isBoosted
        pthread_set_qos_class_self_np(isFast ? QOS_CLASS_USER_INITIATED : QOS_CLASS_BACKGROUND, 0)
    }

    /// Raises the current thread to user-initiated once the job is boosted.
    /// `pthread_set_qos_class_self_np` is the only way to change a running thread's QoS,
    /// and only from that thread.
    mutating func update() {
        guard !isFast, job.isBoosted else { return }
        isFast = true
        if pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0
            && qos_class_self() == QOS_CLASS_USER_INITIATED
        {
            job.boostedWorkers.add(1, ordering: .relaxed)
        }
    }
}

/// The pause flag workers wait on. A condition rather than polling, so a paused stage
/// costs nothing; the timed wait only bounds how late a cancel that forgot to `resume()`
/// is noticed.
private final class PauseGate: @unchecked Sendable {
    /// How often a paused worker rechecks `isCancelled` on its own.
    static let cancelCheckInterval: TimeInterval = 0.25

    private let condition = NSCondition()
    private var paused = false  // guarded by `condition`

    var isPaused: Bool { condition.withLock { paused } }

    func set(paused value: Bool) {
        condition.withLock {
            paused = value
            condition.broadcast()
        }
    }

    func wait(isCancelled: () -> Bool) {
        condition.lock()
        defer { condition.unlock() }
        while paused, !isCancelled() {
            _ = condition.wait(until: Date(timeIntervalSinceNow: Self.cancelCheckInterval))
        }
    }
}

/// A token bucket shared by a stage's workers, so background writes stay under a set rate
/// however many workers there are.
///
/// Each write takes its bytes from the bucket up front and may drive it negative; the
/// writer then sleeps until the bucket would be back at zero. That keeps the average at
/// `bytesPerSecond` with no queue, and lets one buffer through at once after an idle spell
/// (`burstBytes`), so small files aren't delayed by a rate meant for bulk data.
final class WritePacer: Sendable {
    let bytesPerSecond: Double
    let burstBytes: Double
    private let state: Mutex<(tokens: Double, last: UInt64)>
    private static let nanosecondsPerSecond = 1e9

    init(bytesPerSecond: Int, burstBytes: Int) {
        self.bytesPerSecond = Double(max(1, bytesPerSecond))
        self.burstBytes = Double(max(0, burstBytes))
        state = Mutex((tokens: Double(max(0, burstBytes)), last: Self.now()))
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Takes `bytes` and returns how many seconds the caller should wait before writing them.
    func reserve(_ bytes: Int) -> Double {
        let now = Self.now()
        return state.withLock { bucket in
            let elapsed = Double(now &- bucket.last) / Self.nanosecondsPerSecond
            bucket.last = now
            bucket.tokens = min(burstBytes, bucket.tokens + elapsed * bytesPerSecond) - Double(bytes)
            return bucket.tokens < 0 ? -bucket.tokens / bytesPerSecond : 0
        }
    }
}
