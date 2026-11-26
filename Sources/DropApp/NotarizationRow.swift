import Installer
import Observation

/// What the signer card's second row shows (Ready on arrival boards), from the session's
/// `Notarization` and how long ago the current lookup started.
///
/// - A ticket (stapled, or from Apple) or Gatekeeper's acceptance: Notarized by Apple.
/// - Asking Apple: nothing for `notarizationCheckingDelay` (the row's space is kept), then
///   the WaitingRow "Checking with Apple…", then from `notarizationGiveUp` the grey line,
///   until Apple answers (a late "notarized" still swaps the line out).
/// - No network path, or no answer: the grey line at once.
/// - Apple has no ticket, or the signer can't be notarized: "Checking the signature…" after
///   the delay, until the full check lands on the warning or ready board.
enum NotarizationRow: Equatable {
    /// Nothing shown; the row's height is kept.
    case reserved
    case checkingWithApple
    case notarized
    /// "Couldn't reach Apple. macOS checks on first open."
    case unreachable
    /// The full check decides; it is still running.
    case checkingSignature

    /// How far the lookup's clock has run, as the row's thresholds see it.
    enum Phase: Comparable {
        case beforeCheckingDelay, afterCheckingDelay, afterGiveUp
    }

    static func resolve(_ summary: AppSummary, phase: Phase) -> NotarizationRow {
        if summary.isNotarized || summary.notarization.isNotarized { return .notarized }
        switch summary.notarization {
        case .stapled, .confirmed: return .notarized
        case .unreachable: return .unreachable
        case .asking(let attempt):
            switch phase {
            case .afterGiveUp: return .unreachable
            case .afterCheckingDelay: return .checkingWithApple
            // A lookup that starts again after the line was shown keeps the line until the
            // delay, rather than blanking it.
            case .beforeCheckingDelay: return attempt > 1 ? .unreachable : .reserved
            }
        case .notFound, .unknown:
            return phase >= .afterCheckingDelay ? .checkingSignature : .reserved
        }
    }
}

/// Moves `NotarizationRow.Phase` through its thresholds for one lookup. `restart()` begins
/// again from zero (a new lookup after the network came back). The sleep is injected so
/// tests step through time without waiting.
@MainActor
@Observable
final class NotarizationRowClock {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private(set) var phase = NotarizationRow.Phase.beforeCheckingDelay
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let checkingDelay: Duration
    @ObservationIgnored private let giveUp: Duration

    init(
        checkingDelay: Duration = Theme.Timing.notarizationCheckingDelay,
        giveUp: Duration = Theme.Timing.notarizationGiveUp,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.checkingDelay = checkingDelay
        self.giveUp = giveUp
        self.sleep = sleep
    }

    var isRunning: Bool { task != nil }

    /// Starts from zero, cancelling a run in progress.
    func restart() {
        task?.cancel()
        phase = .beforeCheckingDelay
        let sleep = sleep
        let checkingDelay = checkingDelay
        let rest = giveUp - checkingDelay
        task = Task { [weak self] in
            do {
                try await sleep(checkingDelay)
                guard !Task.isCancelled else { return }
                self?.phase = .afterCheckingDelay
                try await sleep(rest)
                guard !Task.isCancelled else { return }
                self?.phase = .afterGiveUp
            } catch {}
        }
    }

    /// Jumps to `phase`, for demo states.
    func set(_ phase: NotarizationRow.Phase) {
        task?.cancel()
        self.phase = phase
    }

    func stop() { task?.cancel() }
}
