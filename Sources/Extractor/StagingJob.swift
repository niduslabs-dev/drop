import Darwin
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

    public init() {}

    /// True once `boost()` has been called.
    public var isBoosted: Bool { boosted.load(ordering: .acquiring) }

    /// Raises the job to user-initiated priority for whatever is left. Returns at once;
    /// the hook runs on this thread, the workers switch themselves.
    public func boost() {
        guard !boosted.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let pending = hook.withLock { hook in
            defer { hook = nil }
            return hook
        }
        pending?()
    }

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
