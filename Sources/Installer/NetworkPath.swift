import Foundation
import Network
import Synchronization

/// Whether the Mac has any usable network path, and when that changes. The session asks it
/// before looking up a notarization ticket online: with no path the answer is known at once
/// ("Couldn't reach Apple"), so the panel never shows "Checking with Apple…" first, and when a
/// path comes back while the panel is open the lookup starts then. Injectable for tests.
public struct NetworkPath: Sendable {
    /// True when some interface can reach the network (`NWPath.Status.satisfied`).
    public var isSatisfied: @Sendable () -> Bool
    /// Yields each new value of `isSatisfied`. Each call makes a new stream; it ends when
    /// the consumer stops iterating.
    public var changes: @Sendable () -> AsyncStream<Bool>

    public init(
        isSatisfied: @escaping @Sendable () -> Bool, changes: @escaping @Sendable () -> AsyncStream<Bool>
    ) {
        self.isSatisfied = isSatisfied
        self.changes = changes
    }

    /// The system's own view, from one `NWPathMonitor` that runs for the app's life (it costs
    /// nothing while idle: the system pushes path changes, nothing polls).
    public static let system: NetworkPath = {
        let monitor = SystemPathMonitor()
        return NetworkPath(isSatisfied: { monitor.isSatisfied }, changes: { monitor.stream() })
    }()

    /// Always online, never changing: for callers that don't care, such as the benchmark.
    public static let alwaysSatisfied = NetworkPath(isSatisfied: { true }, changes: { AsyncStream { $0.finish() } })
}

/// One `NWPathMonitor` and the streams listening to it.
private final class SystemPathMonitor: Sendable {
    private let monitor = NWPathMonitor()
    private let state = Mutex<(satisfied: Bool, listeners: [UUID: AsyncStream<Bool>.Continuation])>(
        (true, [:]))

    init() {
        // Until the first update arrives (a few ms after start), assume a path: a wrong
        // "online" only means the lookup runs and fails, a wrong "offline" would skip it.
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "dev.niduslabs.drop.network-path", qos: .utility))
    }

    var isSatisfied: Bool { state.withLock { $0.satisfied } }

    func stream() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { $0.listeners[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
            }
        }
    }

    private func update(_ satisfied: Bool) {
        let listeners = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
            guard state.satisfied != satisfied else { return [] }
            state.satisfied = satisfied
            return Array(state.listeners.values)
        }
        for listener in listeners { listener.yield(satisfied) }
    }
}
