import Dispatch
import Foundation

/// How a bounded call ended.
public enum Bounded<Value: Sendable>: Sendable {
    case finished(Value)
    /// The time limit passed first. The Security call may still be running on its worker
    /// thread; its result is dropped when it returns.
    case timedOut
    /// The calling task was cancelled first.
    case cancelled
}

extension Bounded: Equatable where Value: Equatable {}

/// Runs blocking Security calls on a worker thread with a time limit and task cancellation.
///
/// Code Signing and syspolicyd calls block, can hash hundreds of megabytes, and the
/// assessment may wait on the network. Neither has a timeout of its own, so the caller's
/// thread waits on a semaphore or continuation instead, and `onStop` gets a chance to
/// interrupt the work (validation can be cancelled; an assessment can only be abandoned).
enum BoundedRun {
    /// One-shot result slot shared by the worker, the timer and the cancel handler.
    private final class Slot<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bounded<Value>, Never>?
        private var done = false

        func install(_ continuation: CheckedContinuation<Bounded<Value>, Never>) -> Bool {
            lock.withLock {
                if done { return false }
                self.continuation = continuation
                return true
            }
        }

        /// Resumes with `outcome` if nothing has yet; returns whether this call did.
        @discardableResult
        func finish(_ outcome: Bounded<Value>) -> Bool {
            let pending: CheckedContinuation<Bounded<Value>, Never>? = lock.withLock {
                if done { return nil }
                done = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: outcome)
            return pending != nil
        }
    }

    private static func dispatchTime(_ duration: Duration) -> DispatchTime {
        let (seconds, attoseconds) = duration.components
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .now() + .nanoseconds(Int(clamping: nanoseconds))
    }

    /// Runs `work` on a new thread rather than a GCD worker. Code Signing fans resource
    /// hashing out over GCD and waits for it, so a few validations parked on GCD workers can
    /// use up the pool and stall each other (seen with 40 in parallel under swift-testing).
    private static func start(_ qos: DispatchQoS.QoSClass, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.qualityOfService = qualityOfService(qos)
        thread.name = "dev.niduslabs.drop.verifier"
        thread.start()
    }

    private static func qualityOfService(_ qos: DispatchQoS.QoSClass) -> QualityOfService {
        switch qos {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        default: .default
        }
    }

    /// Blocks the calling thread for at most `timeout`.
    static func sync<Value: Sendable>(
        timeout: Duration, qos: DispatchQoS.QoSClass, onStop: (@Sendable () -> Void)? = nil,
        _ work: @escaping @Sendable () -> Value
    ) -> Bounded<Value> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<Value>()
        start(qos) {
            box.value = work()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: dispatchTime(timeout)) == .success, let value = box.value else {
            onStop?()
            return .timedOut
        }
        return .finished(value)
    }

    /// Suspends for at most `timeout`, and returns `.cancelled` as soon as the task is.
    static func async<Value: Sendable>(
        timeout: Duration, qos: DispatchQoS.QoSClass, onStop: (@Sendable () -> Void)? = nil,
        _ work: @escaping @Sendable () -> Value
    ) async -> Bounded<Value> {
        let slot = Slot<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard slot.install(continuation) else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                start(qos) { slot.finish(.finished(work())) }
                DispatchQueue.global(qos: qos).asyncAfter(deadline: dispatchTime(timeout)) {
                    if slot.finish(.timedOut) { onStop?() }
                }
            }
        } onCancel: {
            if slot.finish(.cancelled) { onStop?() }
        }
    }
}

/// A value written by one thread and read by another after a semaphore or lock handoff.
final class ValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    init(_ value: Value? = nil) { stored = value }

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
