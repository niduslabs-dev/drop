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
    /// Which way of asking produced this answer.
    public let method: Method

    /// How `assess` reached syspolicyd.
    public enum Method: Sendable, Equatable {
        /// `SecAssessmentCreate` in Security.framework, found at run time (`SecuritySPI`).
        case securityFramework
        /// `/usr/sbin/spctl --assess`, the fallback when that API is missing or broken.
        case spctl
    }

    public init(accepted: Bool, source: String?, status: OSStatus?, method: Method = .securityFramework) {
        self.accepted = accepted
        self.source = source
        self.status = status
        self.method = method
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
    /// Neither way of asking worked: the assessment API is missing or broken, and `spctl`
    /// couldn't be run or printed something unrecognised.
    case unavailable

    public var assessment: Assessment? {
        if case .assessed(let assessment) = self { assessment } else { nil }
    }
}

extension Verifier {
    /// Budget for `assess`. Measured at 0.07–1.6 s online on the real apps (syspolicyd
    /// validates the signature again, then looks up the ticket); the limit is for an online ticket
    /// lookup that hangs on a captive portal or a slow network.
    public static let defaultAssessmentTimeout: Duration = .seconds(30)

    /// Which way `assess` asks syspolicyd. Tests set it with `$assessmentRoute.withValue`;
    /// the app never does.
    @TaskLocal static var assessmentRoute = AssessmentRoute.automatic

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
    /// Asks through `SecAssessmentCreate` first. When that API is missing from this macOS or
    /// answers in a way that means the API itself broke (see `AssessmentRoute`), it runs
    /// `/usr/sbin/spctl --assess` instead, within the same `timeout`, and the result's
    /// `method` says which one answered. Returns `.unavailable` only when both fail.
    ///
    /// There is no way to cancel a framework assessment: on timeout or cancellation this
    /// returns at once and the abandoned call finishes in the background. An `spctl` child is
    /// killed by its PID instead.
    ///
    /// Blocks the calling thread, with the same rule as `validate`: never call this overload
    /// from Swift concurrency or the main thread; use the `async` one there.
    public static func assess(
        app: URL, timeout: Duration = defaultAssessmentTimeout, qos: DispatchQoS.QoSClass = .utility
    ) -> AssessmentResult {
        let route = assessmentRoute
        let child = SpctlChild()
        return result(BoundedRun.sync(timeout: timeout, qos: qos, onStop: child.stop) { route.run(app, child) })
    }

    /// `assess(app:timeout:qos:)` that returns as soon as the calling task is cancelled.
    public static func assess(
        app: URL, timeout: Duration = defaultAssessmentTimeout, qos: DispatchQoS.QoSClass = .utility
    ) async -> AssessmentResult {
        let route = assessmentRoute
        let child = SpctlChild()
        return result(
            await BoundedRun.async(timeout: timeout, qos: qos, onStop: child.stop) { route.run(app, child) })
    }

    private static func result(_ outcome: Bounded<Assessment?>) -> AssessmentResult {
        switch outcome {
        case .finished(let assessment?): .assessed(assessment)
        case .finished(nil): .unavailable
        case .timedOut: .notAssessed(.timedOut)
        case .cancelled: .notAssessed(.cancelled)
        }
    }
}

/// The ways `assess` may ask syspolicyd, in order. Internal so tests can force the `spctl`
/// path, simulate a missing or broken framework API, or point at a stand-in tool.
struct AssessmentRoute: Sendable {
    /// The framework API to try first; nil goes straight to `spctl`, as on a macOS that no
    /// longer exports it.
    var spi: SecuritySPI.Assessment?
    /// The `spctl` to fall back to; nil means no fallback.
    var spctl: URL?

    static let systemSpctl = URL(fileURLWithPath: "/usr/sbin/spctl")
    static let automatic = AssessmentRoute(spi: SecuritySPI.assessment, spctl: systemSpctl)
    /// The fallback alone: what every Mac gets if `SecAssessmentCreate` disappears.
    static let spctlOnly = AssessmentRoute(spi: nil, spctl: systemSpctl)
    /// The framework alone, as before the fallback existed.
    static let frameworkOnly = AssessmentRoute(spi: SecuritySPI.assessment, spctl: nil)

    /// Nil when no route produced an answer.
    func run(_ app: URL, _ child: SpctlChild) -> Assessment? {
        if let spi, let assessment = Self.framework(spi, app) { return assessment }
        guard let spctl else { return nil }
        return Spctl.assess(app, tool: spctl, child: child)
    }

    /// Asks through `SecAssessmentCreate`, or returns nil when the answer means the API
    /// itself is broken rather than the app being rejected:
    ///
    /// - `SecAssessmentCreate` fails with no error, or with one that isn't a Code Signing
    ///   status (`Spctl.codeSigningStatuses`). A damaged or unsigned app always fails with a
    ///   Code Signing status (`errSecCSBadResource`, `errSecCSUnsigned`); anything else, such
    ///   as `errSecUnimplemented` or a POSIX or XPC error, means the call never reached a verdict.
    /// - `SecAssessmentCopyResult` returns nothing.
    /// - The result has no Boolean verdict under `kSecAssessmentAssessmentVerdict`, so the
    ///   keys or the dictionary's shape changed.
    static func framework(_ spi: SecuritySPI.Assessment, _ app: URL) -> Assessment? {
        let (result, error) = spi.assess(app)
        guard let result else {
            // SecAssessmentCreate fails outright (no result dictionary) when the code is
            // damaged; the error carries the code signing status.
            guard let error else { return nil }
            let status = OSStatus(truncatingIfNeeded: CFErrorGetCode(error))
            guard CFErrorGetDomain(error) as String == kCFErrorDomainOSStatus as String,
                Spctl.codeSigningStatuses.contains(status)
            else { return nil }
            return Assessment(accepted: false, source: nil, status: status)
        }
        guard let accepted = result[spi.verdictKey as String] as? Bool else { return nil }
        let authority = result[spi.authorityKey as String] as? [String: Any]
        let source = (authority?[spi.sourceKey as String] ?? result[spi.sourceKey as String]) as? String
        let status = (result[spi.codeSigningErrorKey as String] as? NSNumber).map { OSStatus(truncating: $0) }
        return Assessment(accepted: accepted, source: source, status: status)
    }
}
