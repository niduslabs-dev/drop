import Darwin
import Foundation
import Security

/// The Security functions Drop needs that the macOS SDK ships without a header.
///
/// `SecAssessment` (what `spctl` and Finder use for Gatekeeper's verdict) lost its public
/// header years ago but is still exported from Security.framework and listed in its `.tbd`.
/// `SecStaticCodeCancelValidation` is private API that stops a running
/// `SecStaticCodeCheckValidity` from another thread. Both are found with `dlsym` and called
/// through `@convention(c)` types, so a missing symbol degrades (no assessment, or no early
/// cancel) instead of failing to load. The signatures match Apple's open-source
/// `Security/OSX/libsecurity_codesigning/lib/SecAssessment.h` and `SecStaticCodePriv.h`.
enum SecuritySPI {
    typealias AssessmentCreate =
        @convention(c) (
            CFURL, UInt64, CFDictionary?, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFTypeRef>?
    typealias AssessmentCopyResult =
        @convention(c) (
            CFTypeRef, UInt64, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFDictionary>?
    typealias CancelValidation = @convention(c) (SecStaticCode, SecCSFlags) -> OSStatus

    /// `kSecAssessmentDefaultFlags`: let syspolicyd assess, using its cache.
    static let defaultAssessmentFlags: UInt64 = 0

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
    }

    private static func string(_ name: String) -> CFString? {
        symbol(name)?.assumingMemoryBound(to: CFString.self).pointee
    }

    /// The assessment functions and keys, or nil when this macOS doesn't export them.
    /// Immutable: C function pointers and constant CFStrings exported by Security, safe to share.
    struct Assessment: @unchecked Sendable {
        let create: AssessmentCreate
        let copyResult: AssessmentCopyResult
        let operationKey: CFString
        let operationExecute: CFString
        let verdictKey: CFString
        let authorityKey: CFString
        let sourceKey: CFString
        let originatorKey: CFString
        let codeSigningErrorKey: CFString

        /// Runs `SecAssessmentCreate` (execute) then `SecAssessmentCopyResult`. Blocks while
        /// syspolicyd works, which can include an online ticket lookup.
        func assess(_ url: URL) -> (result: [String: Any]?, error: CFError?) {
            var error: Unmanaged<CFError>?
            let context = [operationKey: operationExecute] as CFDictionary
            guard let assessment = create(url as CFURL, SecuritySPI.defaultAssessmentFlags, context, &error) else {
                return (nil, error?.takeRetainedValue())
            }
            let handle = assessment.takeRetainedValue()
            var copyError: Unmanaged<CFError>?
            let result = copyResult(handle, SecuritySPI.defaultAssessmentFlags, &copyError)?.takeRetainedValue()
            return (result as? [String: Any], copyError?.takeRetainedValue())
        }
    }

    /// Looked up once; nil when any symbol is missing.
    static let assessment: Assessment? = {
        guard let create = symbol("SecAssessmentCreate"), let copy = symbol("SecAssessmentCopyResult"),
            let operationKey = string("kSecAssessmentContextKeyOperation"),
            let operationExecute = string("kSecAssessmentOperationTypeExecute"),
            let verdictKey = string("kSecAssessmentAssessmentVerdict"),
            let authorityKey = string("kSecAssessmentAssessmentAuthority"),
            let sourceKey = string("kSecAssessmentAssessmentSource"),
            let originatorKey = string("kSecAssessmentAssessmentOriginator"),
            let codeSigningErrorKey = string("kSecAssessmentAssessmentCodeSigningError")
        else { return nil }
        return Assessment(
            create: unsafeBitCast(create, to: AssessmentCreate.self),
            copyResult: unsafeBitCast(copy, to: AssessmentCopyResult.self),
            operationKey: operationKey, operationExecute: operationExecute, verdictKey: verdictKey,
            authorityKey: authorityKey, sourceKey: sourceKey, originatorKey: originatorKey,
            codeSigningErrorKey: codeSigningErrorKey)
    }()

    private static let cancelValidation: CancelValidation? = symbol("SecStaticCodeCancelValidation").map {
        unsafeBitCast($0, to: CancelValidation.self)
    }

    /// Asks a running validation of `code` to stop; it then returns `errSecCSCancelled`.
    /// Returns false when the call isn't available.
    @discardableResult
    static func cancel(_ code: SecStaticCode) -> Bool {
        guard let cancelValidation else { return false }
        return cancelValidation(code, []) == errSecSuccess
    }
}
