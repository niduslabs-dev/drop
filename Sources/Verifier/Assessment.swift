import Dispatch
import Foundation
import Security

/// Gatekeeper's verdict on running an app, as `spctl -a -t exec` reports it.
public struct Assessment: Sendable, Equatable {
    /// The `source` strings syspolicyd reports. Others exist (rule labels a user or MDM
    /// added); compare with these, never parse.
    public enum Source {
        public static let notarizedDeveloperID = "Notarized Developer ID"
        public static let developerID = "Developer ID"
        public static let appleSystem = "Apple System"
        public static let macAppStore = "Mac App Store"
        public static let noUsableSignature = "no usable signature"
        /// Sources that mean Apple has checked this exact code: notarized, Apple's own, or
        /// reviewed for the App Store.
        public static let checkedByApple: Set<String> = [notarizedDeveloperID, appleSystem, macAppStore]
    }

    public let accepted: Bool
    /// What made the decision, e.g. "Notarized Developer ID"; nil when syspolicyd named
    /// none (it names none for a rejected ad hoc app or an Apple Development signature).
    public let source: String?
    /// The code signing error syspolicyd hit, when it hit one: `errSecCSBadResource` for a
    /// tampered app, `errSecCSRevokedNotarization` when Apple revoked the notarization.
    public let status: OSStatus?

    public init(accepted: Bool, source: String?, status: OSStatus?) {
        self.accepted = accepted
        self.source = source
        self.status = status
    }

    /// Accepted because Apple checked it: the gate for skipping the first-open prompt.
    public var isCheckedByApple: Bool { accepted && source.map(Source.checkedByApple.contains) == true }
    /// Apple revoked this app's notarization (known malware or a revoked developer).
    public var isRevoked: Bool { status == errSecCSRevokedNotarization }
}

/// How `assess` ended.
public enum AssessmentResult: Sendable, Equatable {
    case assessed(Assessment)
    /// syspolicyd didn't answer in time (or the task was cancelled). Likely offline with an
    /// unstapled app waiting on the ticket lookup.
    case notAssessed(Validity.Stopped)
    /// This macOS doesn't export the assessment API.
    case unavailable

    public var assessment: Assessment? {
        if case .assessed(let assessment) = self { assessment } else { nil }
    }
}

extension Verifier {
    /// Budget for `assess`. Measured at 0.07–1.2 s online on the real apps (syspolicyd
    /// validates the signature again, then looks up the ticket); the limit is for an online ticket
    /// lookup that hangs on a captive portal or a slow network.
    public static let defaultAssessmentTimeout: Duration = .seconds(30)

    /// Asks Gatekeeper (syspolicyd) whether `app` may run, exactly as a first launch would,
    /// minus the prompt.
    ///
    /// syspolicyd checks the signature, then the notarization ticket: the stapled one, or
    /// one fetched from Apple's CloudKit ticket service when none is stapled. So the answer
    /// for an unstapled app depends on the network. Not tested offline (it needs the network
    /// cut); from Apple's docs and the gatekeeper spike, expect a stapled app to pass offline
    /// and an unstapled one to fail the lookup, which surfaces as a rejection or a timeout.
    /// Staple the DMG's ticket first (`staple(_:into:)`) so the answer is the same either way.
    ///
    /// There is no way to cancel an assessment: on timeout or cancellation this returns at
    /// once and the abandoned call finishes in the background.
    ///
    /// Blocks the calling thread, with the same rule as `validate`: never call this overload
    /// from Swift concurrency or the main thread; use the `async` one there.
    public static func assess(
        app: URL, timeout: Duration = defaultAssessmentTimeout, qos: DispatchQoS.QoSClass = .utility
    ) -> AssessmentResult {
        guard SecuritySPI.assessment != nil else { return .unavailable }
        return result(BoundedRun.sync(timeout: timeout, qos: qos) { runAssessment(app) })
    }

    /// `assess(app:timeout:qos:)` that returns as soon as the calling task is cancelled.
    public static func assess(
        app: URL, timeout: Duration = defaultAssessmentTimeout, qos: DispatchQoS.QoSClass = .utility
    ) async -> AssessmentResult {
        guard SecuritySPI.assessment != nil else { return .unavailable }
        return result(await BoundedRun.async(timeout: timeout, qos: qos) { runAssessment(app) })
    }

    private static func result(_ outcome: Bounded<Assessment>) -> AssessmentResult {
        switch outcome {
        case .finished(let assessment): .assessed(assessment)
        case .timedOut: .notAssessed(.timedOut)
        case .cancelled: .notAssessed(.cancelled)
        }
    }

    private static func runAssessment(_ app: URL) -> Assessment {
        guard let spi = SecuritySPI.assessment else { return Assessment(accepted: false, source: nil, status: nil) }
        let (result, error) = spi.assess(app)
        guard let result else {
            // SecAssessmentCreate fails outright (no result dictionary) when the code is
            // damaged; the error carries the code signing status.
            let status = error.map { OSStatus(truncatingIfNeeded: CFErrorGetCode($0)) }
            return Assessment(accepted: false, source: nil, status: status)
        }
        let authority = result[spi.authorityKey as String] as? [String: Any]
        let source = (authority?[spi.sourceKey as String] ?? result[spi.sourceKey as String]) as? String
        let accepted = (result[spi.verdictKey as String] as? Bool) ?? false
        let status = (result[spi.codeSigningErrorKey as String] as? NSNumber).map { OSStatus(truncating: $0) }
        return Assessment(accepted: accepted, source: source, status: status)
    }
}
