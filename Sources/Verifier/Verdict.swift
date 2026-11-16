import Dispatch
import Foundation
import Security

/// What Drop's popup does with a staged app, from its signature and Gatekeeper's verdict.
///
/// Matches the design boards: a notarized app installs normally; a valid but not notarized
/// app, or an unsigned one, gets the "Apple hasn't checked this app" warning with Install
/// Anyway; a damaged app is a hard stop with no Install Anyway.
public struct Verdict: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Notarized (or Apple's own, or from the App Store) and intact. Install as normal;
        /// the only case where the skip-prompt setting may apply.
        case install
        /// "Apple hasn't checked this app". The user may Install Anyway.
        case warn(Warning)
        /// Hard stop: no Install Anyway, and the installed copy is never touched.
        case refuse(Refusal)
    }

    public enum Warning: Sendable, Equatable {
        /// A valid signature that Gatekeeper doesn't accept as notarized: Developer ID
        /// without a ticket, ad hoc, Apple Development, or a non-Apple certificate.
        case notNotarized
        /// No signature at all.
        case unsigned
        /// The signature is valid but Gatekeeper couldn't be asked (timed out, likely
        /// offline with no stapled ticket, or both the API and `spctl` failed).
        case notarizationUnknown
    }

    public enum Refusal: Sendable, Equatable {
        /// The signature doesn't hold: the app was changed after signing or is broken.
        case damaged(reason: String, status: OSStatus, path: String?)
        /// Apple revoked the notarization (`errSecCSRevokedNotarization`).
        case revoked
        /// The signature check timed out or was cancelled, so nothing is known. Not shown
        /// as "damaged"; the app may retry.
        case notChecked(Validity.Stopped)
    }

    public let decision: Decision
    /// Who signed it, for the popup. Nil only when the signature couldn't be read at all.
    public let signing: SigningInfo?
    public let validity: Validity
    /// Nil when the assessment was skipped (unsigned or damaged code needs none).
    public let assessment: AssessmentResult?

    /// Combines the three checks. Pure, so every rule is testable without an app.
    public init(signing: SigningInfo?, validity: Validity, assessment: AssessmentResult?) {
        self.signing = signing
        self.validity = validity
        self.assessment = assessment
        decision = Self.decide(signing: signing, validity: validity, assessment: assessment)
    }

    private static func decide(signing: SigningInfo?, validity: Validity, assessment: AssessmentResult?) -> Decision {
        switch validity {
        case .invalid(let reason, let status, let path):
            return .refuse(.damaged(reason: reason, status: status, path: path))
        case .notChecked(let stopped):
            return .refuse(.notChecked(stopped))
        case .unsigned:
            return .warn(.unsigned)
        case .valid:
            break
        }
        guard let assessment else { return .warn(.notarizationUnknown) }
        switch assessment {
        case .assessed(let result):
            if result.isRevoked { return .refuse(.revoked) }
            if result.status == errSecCSBadResource || result.status == errSecCSSignatureFailed {
                // Gatekeeper found damage our local check missed (a race with a write).
                let status = result.status ?? errSecCSBadResource
                return .refuse(.damaged(reason: Verifier.describe(nil, status: status), status: status, path: nil))
            }
            if result.isCheckedByApple { return .install }
            if signing?.kind == .unsigned { return .warn(.unsigned) }
            return .warn(.notNotarized)
        case .notAssessed, .unavailable:
            return .warn(.notarizationUnknown)
        }
    }

    /// True when the skip-prompt setting may write quarantine pre-approved: only for an
    /// intact app Gatekeeper accepted as checked by Apple.
    public var allowsPreApproval: Bool {
        decision == .install && assessment?.assessment?.isCheckedByApple == true
    }
}

extension Verifier {
    /// Runs `validate`, `signingInfo` and `assess` on a staged app and combines them.
    ///
    /// Skips the assessment when the signature is damaged or absent (Gatekeeper would only
    /// repeat the answer). Typical cost is dominated by `validate`; see the timing test.
    ///
    /// At `.userInitiated` (someone is waiting on Install) the two run side by side, since
    /// syspolicyd hashes the bundle again on its own: about 40% off the wait for big apps
    /// (`impact-bench.md`, round 2). The assessment is dropped, and cancelled, when the
    /// signature turns out not to be valid. At lower QoS they stay one after the other,
    /// so background checking never doubles its disk and CPU use.
    public static func verdict(
        app: URL, validationTimeout: Duration = defaultValidationTimeout,
        assessmentTimeout: Duration = defaultAssessmentTimeout, qos: DispatchQoS.QoSClass = .utility
    ) async -> Verdict {
        if qos == .userInitiated || qos == .userInteractive {
            async let parallelAssessment = assess(app: app, timeout: assessmentTimeout, qos: qos)
            let validity = await validate(app: app, timeout: validationTimeout, qos: qos)
            let signing = try? signingInfo(app: app)
            // Leaving the scope without awaiting cancels the assessment and waits for it,
            // which returns at once on cancellation (see `BoundedRun.async`).
            guard validity == .valid else { return Verdict(signing: signing, validity: validity, assessment: nil) }
            return Verdict(signing: signing, validity: validity, assessment: await parallelAssessment)
        }
        let validity = await validate(app: app, timeout: validationTimeout, qos: qos)
        let signing = try? signingInfo(app: app)
        let assessment: AssessmentResult? =
            validity == .valid ? await assess(app: app, timeout: assessmentTimeout, qos: qos) : nil
        return Verdict(signing: signing, validity: validity, assessment: assessment)
    }
}

/// Whether an update comes from the developer of the copy it replaces.
public enum DeveloperMatch: Sendable, Equatable {
    /// Same Team ID (or both signed by Apple itself).
    case same(teamID: String?)
    /// Different Team IDs: someone else signed this "update". Drop warns before replacing.
    case different(new: String, installed: String)
    /// The installed copy has no Team ID (unsigned or ad hoc), so there is nothing to
    /// compare against. Not a mismatch, but not a confirmation either.
    case installedUnsigned
    /// The new copy has no Team ID while the installed one has: a signed app replaced by
    /// an unsigned or ad hoc one.
    case newUnsigned(installed: String)

    public var isSame: Bool { if case .same = self { true } else { false } }
}

extension Verifier {
    /// Compares Team IDs, the identity Gatekeeper and Keychain use for "same developer".
    /// Names can change (a company rename) without the Team ID changing, and vice versa a
    /// look-alike name can't fake a Team ID.
    public static func sameDeveloper(new: SigningInfo, installed: SigningInfo) -> DeveloperMatch {
        if new.kind == .apple && installed.kind == .apple { return .same(teamID: new.teamID) }
        guard let installedTeam = installed.teamID else { return .installedUnsigned }
        guard let newTeam = new.teamID else { return .newUnsigned(installed: installedTeam) }
        return newTeam == installedTeam ? .same(teamID: newTeam) : .different(new: newTeam, installed: installedTeam)
    }
}
