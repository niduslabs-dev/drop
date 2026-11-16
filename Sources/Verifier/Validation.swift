import Dispatch
import Foundation
import Security

/// Whether an app's signature is intact: every architecture, every nested bundle and
/// every sealed resource.
public enum Validity: Sendable, Equatable {
    case valid
    /// No signature at all. Not damage: Drop warns and offers Install Anyway.
    case unsigned
    /// The signature is there but doesn't hold: a changed, missing or added file, a bad
    /// nested bundle, a malformed signature. Drop refuses to install.
    /// `path` is the first file Code Signing named, when it named one.
    case invalid(reason: String, status: OSStatus, path: String?)
    /// The check didn't finish in time or was cancelled; nothing is known.
    case notChecked(Stopped)

    public enum Stopped: Sendable, Equatable {
        case timedOut
        case cancelled
    }
}

extension Verifier {
    /// Budget for `validate`: well over 30 times the slowest app measured (Slack, 1.6 s on
    /// an M-series Mac; most apps take 40–600 ms), so only a hung disk or a huge app on a
    /// slow external drive hits it.
    public static let defaultValidationTimeout: Duration = .seconds(60)

    /// The validation flags. Strict, deep, every architecture, and local only:
    ///
    /// - `kSecCSCheckAllArchitectures`: a universal app runs on Intel too; a bad slice is damage.
    /// - `kSecCSCheckNestedCode`: frameworks, helpers and XPC services, like `codesign --deep`.
    /// - `kSecCSStrictValidate`: rejects the malformed bundles strict Gatekeeper rejects.
    /// - `kSecCSNoNetworkAccess` instead of `kSecCSEnforceRevocationChecks`: enforced
    ///   revocation fails the check when OCSP can't be reached, so an offline Mac would see a
    ///   good app as damaged, a hard stop with no Install Anyway. Revocation is Gatekeeper's
    ///   job at first launch (it checks the certificate and the notarization ticket online),
    ///   and `assess` reports it before install when online. This check answers only "are
    ///   these bytes what the developer signed", which needs no network and can't hang on it.
    static let validationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
    ).union(.noNetworkAccess)

    /// Checks the signature of `app` in full and waits at most `timeout`.
    ///
    /// Hashes every sealed file, so it costs about a read of the bundle (see the timing
    /// test). On timeout the validation is cancelled and the worker thread exits soon after.
    ///
    /// Blocks the calling thread: call it from a plain thread or GCD queue, never from
    /// Swift concurrency (a `Task` or actor), and never from the main thread. Code Signing
    /// waits on GCD work of its own, and a few cooperative threads parked here can starve it
    /// until every call times out (seen with 11 at once under swift-testing). From async
    /// code use the `async` overload, which parks no thread.
    public static func validate(
        app: URL, timeout: Duration = defaultValidationTimeout, qos: DispatchQoS.QoSClass = .utility
    ) -> Validity {
        let running = ValidationHandle()
        let outcome = BoundedRun.sync(
            timeout: timeout, qos: qos, onStop: { cancel(running) }, { runValidation(app: app, running: running) })
        return validity(outcome)
    }

    /// `validate(app:timeout:qos:)` that also stops as soon as the calling task is cancelled.
    public static func validate(
        app: URL, timeout: Duration = defaultValidationTimeout, qos: DispatchQoS.QoSClass = .utility
    ) async -> Validity {
        let running = ValidationHandle()
        let outcome = await BoundedRun.async(
            timeout: timeout, qos: qos, onStop: { cancel(running) }, { runValidation(app: app, running: running) })
        return validity(outcome)
    }

    private static func cancel(_ running: ValidationHandle) {
        if let code = running.stop() { SecuritySPI.cancel(code) }
    }

    private static func validity(_ outcome: Bounded<Validity>) -> Validity {
        switch outcome {
        case .finished(let validity): validity
        case .timedOut: .notChecked(.timedOut)
        case .cancelled: .notChecked(.cancelled)
        }
    }

    /// `running` hands the code object to the cancel handler (and stops a validation that
    /// was cancelled before it began). SecStaticCode is a
    /// thread-safe CF object and `SecStaticCodeCancelValidation` exists to be called from
    /// another thread while this one is inside `SecStaticCodeCheckValidityWithErrors`.
    private static func runValidation(app: URL, running: ValidationHandle) -> Validity {
        let code: SecStaticCode
        do {
            code = try staticCode(app)
        } catch let error as VerifierError {
            return .invalid(reason: "not code", status: error.status, path: app.path)
        } catch {
            return .invalid(reason: "\(error)", status: errSecCSInternalError, path: app.path)
        }
        guard running.start(code) else { return .notChecked(.cancelled) }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, validationFlags, nil, &error)
        let cfError = error?.takeRetainedValue()
        switch status {
        case errSecSuccess:
            return .valid
        case errSecCSUnsigned:
            return .unsigned
        case errSecCSCancelled:
            return .notChecked(.cancelled)
        default:
            return .invalid(reason: describe(cfError, status: status), status: status, path: firstPath(cfError))
        }
    }

    static func describe(_ error: CFError?, status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? { return message }
        if let error { return CFErrorCopyDescription(error) as String }
        return "code signing error \(status)"
    }

    /// The first file a Code Signing error names: altered, missing or added resources,
    /// else the code path it was looking at.
    private static func firstPath(_ error: CFError?) -> String? {
        guard let error, let info = CFErrorCopyUserInfo(error) as? [String: Any] else { return nil }
        for key in [kSecCFErrorResourceAltered, kSecCFErrorResourceMissing, kSecCFErrorResourceAdded] {
            if let items = info[key as String] as? [Any], let first = items.first {
                if let url = first as? URL { return url.path }
                if let string = first as? String { return string }
            }
        }
        if let url = info[kSecCFErrorPath as String] as? URL { return url.path }
        return info[kSecCFErrorPath as String] as? String
    }
}

/// The code object being validated, shared between the worker and the cancel handler.
///
/// SecStaticCode is a thread-safe CF object, and `SecStaticCodeCancelValidation` exists to
/// be called from another thread during a validation, so sharing it under a lock is sound.
private final class ValidationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var code: SecStaticCode?
    private var stopped = false

    /// Records `code`; false when a stop already came, so the worker shouldn't begin.
    func start(_ code: SecStaticCode) -> Bool {
        lock.withLock {
            self.code = code
            return !stopped
        }
    }

    /// Marks the validation stopped and returns the code to cancel, if it has started.
    func stop() -> SecStaticCode? {
        lock.withLock {
            stopped = true
            return code
        }
    }
}
