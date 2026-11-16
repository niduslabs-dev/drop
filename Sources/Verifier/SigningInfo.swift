import Foundation
import Security

/// A code directory hash, as notarization tickets and `codesign -dvvv` (`CDHash=`) list it.
public struct CDHash: Sendable, Hashable, CustomStringConvertible {
    /// The code directory's digest type (`kSecCodeSignatureHashSHA256` is 2, SHA-1 is 1).
    public let hashType: UInt8
    /// The digest truncated to 20 bytes, the form Code Signing calls the cdhash.
    public let bytes: [UInt8]

    /// Length of a cdhash whatever the digest: longer digests are truncated to this.
    public static let length = 20

    public init(hashType: UInt8, bytes: [UInt8]) {
        self.hashType = hashType
        self.bytes = bytes
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hex }
}

/// Who signed an app and how, read from its signature without checking the signature is
/// intact (that is `Verifier.validate`). Safe to show before install.
public struct SigningInfo: Sendable, Equatable {
    /// What kind of signer, from Apple's certificate policy markers in the chain.
    public enum Kind: Sendable, Equatable {
        /// Developer ID Application: the normal case for a DMG download.
        case developerID
        /// Signed by Apple itself (`anchor apple`): Apple's own apps.
        case apple
        /// Re-signed by the Mac App Store.
        case appStore
        /// Another Apple-issued certificate, such as Apple Development or Apple
        /// Distribution: valid, but Gatekeeper never accepts it for a download.
        case otherAppleIssued
        /// A certificate that doesn't chain to Apple's root.
        case otherCertificate
        /// Ad hoc (`codesign -s -`): a valid seal with no signer at all.
        case adHoc
        case unsigned
    }

    public let kind: Kind
    /// The signing identifier (usually the bundle ID); nil when unsigned.
    public let identifier: String?
    /// The Team ID of the leaf certificate; nil for ad hoc, unsigned and Apple's own code.
    public let teamID: String?
    /// The leaf certificate's common name, e.g. "Developer ID Application: Ryan Hanson (XSYZ3E4B7D)".
    public let signer: String?
    /// The leaf certificate's organisation (O=), e.g. "Ryan Hanson".
    public let organisation: String?
    /// True when the certificate chain ends at an Apple root (`anchor apple generic`).
    public let anchoredToApple: Bool
    /// Every cdhash of the main executable: one per architecture and per digest type.
    public let cdhashes: [CDHash]
    /// The hardened runtime flag, which notarization requires.
    public let hardenedRuntime: Bool
    /// True when a notarization ticket is already stapled (`Contents/CodeResources`).
    public let hasStapledTicket: Bool

    public init(
        kind: Kind, identifier: String?, teamID: String?, signer: String?, organisation: String?,
        anchoredToApple: Bool, cdhashes: [CDHash], hardenedRuntime: Bool, hasStapledTicket: Bool
    ) {
        self.kind = kind
        self.identifier = identifier
        self.teamID = teamID
        self.signer = signer
        self.organisation = organisation
        self.anchoredToApple = anchoredToApple
        self.cdhashes = cdhashes
        self.hardenedRuntime = hardenedRuntime
        self.hasStapledTicket = hasStapledTicket
    }

    /// Whether `kind` is a real signer (not ad hoc or unsigned).
    public var hasSigner: Bool { kind != .adHoc && kind != .unsigned }
}

/// Why signing information couldn't be read at all. A damaged signature is not this:
/// `signingInfo` still reads what it can, and `validate` reports the damage.
public struct VerifierError: Error, Sendable, Equatable, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus
    public var description: String { "\(operation) failed (\(status))" }
}

extension Verifier {
    /// Designated requirements that classify the signer. They test Apple's certificate
    /// extension markers (OIDs from Apple's Certification Practice Statement): `6.1.13`
    /// Developer ID Application leaf, `6.2.6` Developer ID intermediate, `6.1.9` Mac App
    /// Store leaf. The same strings `codesign` and Gatekeeper use.
    private enum Requirement {
        static let apple = "anchor apple"
        static let appleGeneric = "anchor apple generic"
        static let developerID =
            "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        static let appStore = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]"
    }

    /// The `CS_RUNTIME` code directory flag (`kSecCodeSignatureRuntime`).
    private static let runtimeFlag = SecCodeSignatureFlags.runtime.rawValue
    /// The `CS_ADHOC` code directory flag (`kSecCodeSignatureAdhoc`).
    private static let adHocFlag = SecCodeSignatureFlags.adhoc.rawValue

    /// Reads who signed `app` and its cdhashes for every architecture.
    ///
    /// Reads the signature only: it doesn't hash the executable or resources, so a
    /// tampered app still reports its signer here. Typically a few milliseconds.
    /// Throws only when the path isn't code at all (missing, not a bundle).
    public static func signingInfo(app: URL) throws -> SigningInfo {
        let code = try staticCode(app)
        let info = try copyInfo(code)
        guard info[kSecCodeInfoUnique as String] != nil else {
            return SigningInfo(
                kind: .unsigned, identifier: nil, teamID: nil, signer: nil, organisation: nil,
                anchoredToApple: false, cdhashes: [], hardenedRuntime: false, hasStapledTicket: false)
        }

        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        let leaf = certificates.first
        let anchored = satisfies(code, Requirement.appleGeneric)
        let kind: SigningInfo.Kind
        if flags & adHocFlag != 0 || leaf == nil {
            kind = .adHoc
        } else if satisfies(code, Requirement.apple) {
            kind = .apple
        } else if satisfies(code, Requirement.developerID) {
            kind = .developerID
        } else if satisfies(code, Requirement.appStore) {
            kind = .appStore
        } else {
            kind = anchored ? .otherAppleIssued : .otherCertificate
        }

        var commonName: CFString?
        if let leaf { SecCertificateCopyCommonName(leaf, &commonName) }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String

        return SigningInfo(
            kind: kind,
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: teamID?.isEmpty == false ? teamID : nil,
            signer: commonName as String?,
            organisation: leaf.flatMap(organisation(of:)),
            anchoredToApple: anchored,
            cdhashes: try allArchitectureCDHashes(app: app, primary: info),
            hardenedRuntime: flags & runtimeFlag != 0,
            hasStapledTicket: info[kSecCodeInfoStapledNotarizationTicket as String] != nil
                || hasTicketFile(app: app))
    }

    static func staticCode(_ url: URL, attributes: [String: Any]? = nil) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status =
            if let attributes {
                SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes as CFDictionary, &code)
            } else {
                SecStaticCodeCreateWithPath(url as CFURL, [], &code)
            }
        guard status == errSecSuccess, let code else {
            throw VerifierError(operation: "SecStaticCodeCreateWithPath", status: status)
        }
        return code
    }

    private static func copyInfo(_ code: SecStaticCode) throws -> [String: Any] {
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSContentInformation)
        let status = SecCodeCopySigningInformation(code, flags, &info)
        guard status == errSecSuccess, let dictionary = info as? [String: Any] else {
            throw VerifierError(operation: "SecCodeCopySigningInformation", status: status)
        }
        return dictionary
    }

    /// Checks `requirement` against the signature only (no executable or resource hashing),
    /// which is all classifying the signer needs.
    private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func organisation(of certificate: SecCertificate) -> String? {
        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
            let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
            let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }
        let field = fields.first {
            ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationName as String)
        }
        return field?[kSecPropertyKeyValue as String] as? String
    }

    /// The cdhashes from `primary` (the architecture Code Signing picked) plus those of every
    /// other architecture in the main executable. A notarization ticket lists each slice, and
    /// a universal app is covered as long as any one of them matches.
    private static func allArchitectureCDHashes(app: URL, primary: [String: Any]) throws -> [CDHash] {
        var hashes = cdhashes(in: primary)
        let architectures = Bundle(url: app)?.executableArchitectures ?? []
        if architectures.count > 1 {
            for architecture in architectures {
                let attributes = [kSecCodeAttributeArchitecture as String: architecture]
                guard let slice = try? staticCode(app, attributes: attributes), let info = try? copyInfo(slice)
                else { continue }
                for hash in cdhashes(in: info) where !hashes.contains(hash) { hashes.append(hash) }
            }
        }
        return hashes
    }

    /// `kSecCodeInfoCdHashes` paired with `kSecCodeInfoDigestAlgorithms` (same order, one per
    /// code directory). Falls back to `kSecCodeInfoUnique` with the primary digest type.
    private static func cdhashes(in info: [String: Any]) -> [CDHash] {
        let values = (info[kSecCodeInfoCdHashes as String] as? [Data]) ?? []
        let types = (info[kSecCodeInfoDigestAlgorithms as String] as? [NSNumber]) ?? []
        if !values.isEmpty {
            return values.enumerated().map { index, data in
                let type = index < types.count ? types[index].uint8Value : 0
                return CDHash(hashType: type, bytes: Array(data.prefix(CDHash.length)))
            }
        }
        guard let unique = info[kSecCodeInfoUnique as String] as? Data else { return [] }
        let type = (info[kSecCodeInfoDigestAlgorithm as String] as? NSNumber)?.uint8Value ?? 0
        return [CDHash(hashType: type, bytes: Array(unique.prefix(CDHash.length)))]
    }

    /// The stapled ticket's file. Code Signing reports it in `kSecCodeInfoStapledNotarizationTicket`
    /// too; checking the file as well covers anything already sitting at that path.
    static func ticketURL(app: URL) -> URL { app.appending(path: "Contents/CodeResources") }

    static func hasTicketFile(app: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: ticketURL(app: app)) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: NotarizationTicket.magic.count)) ?? Data()
        return Array(head) == NotarizationTicket.magic
    }
}
