import Foundation

/// Whether the Mac wants background work held back right now, and when that may change.
///
/// The plan's rule: in Low Power Mode, or at a thermal state of serious or worse, a new DMG
/// is read and its summary shown, but nothing is staged until Install; if the state turns
/// on mid-stage, staging pauses between files and picks up when it turns off.
/// Injectable so tests can flip it without touching system settings.
public struct StagingConditions: Sendable {
    /// True when staging should wait for Install.
    public var isConstrained: @Sendable () -> Bool
    /// A stream that yields whenever `isConstrained` may have changed. Each call makes a new
    /// stream; it ends when the consumer stops iterating.
    public var changes: @Sendable () -> AsyncStream<Void>

    public init(
        isConstrained: @escaping @Sendable () -> Bool, changes: @escaping @Sendable () -> AsyncStream<Void>
    ) {
        self.isConstrained = isConstrained
        self.changes = changes
    }

    /// Low Power Mode or a thermal state of `.serious` or `.critical`, watched through
    /// `NSProcessInfoPowerStateDidChange` and `ProcessInfo.thermalStateDidChangeNotification`.
    /// No polling: both are posted by the system.
    public static let system = StagingConditions(
        isConstrained: {
            let info = ProcessInfo.processInfo
            return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        },
        changes: {
            AsyncStream { continuation in
                let center = NotificationCenter.default
                let names: [Notification.Name] = [
                    .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
                ]
                let tokens = ObserverTokens(
                    names.map { center.addObserver(forName: $0, object: nil, queue: nil) { _ in continuation.yield() } }
                )
                continuation.onTermination = { _ in tokens.remove(from: center) }
            }
        })

    /// Never constrained: staging always runs. For callers that already asked to install.
    public static let unconstrained = StagingConditions(
        isConstrained: { false }, changes: { AsyncStream { $0.finish() } })
}

/// NotificationCenter observer tokens, removed once when the stream ends. The tokens are
/// opaque objects NotificationCenter owns and allows removing from any thread.
private final class ObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol]  // guarded by `lock`

    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }

    func remove(from center: NotificationCenter) {
        let taken = lock.withLock {
            defer { tokens = [] }
            return tokens
        }
        for token in taken { center.removeObserver(token) }
    }
}
