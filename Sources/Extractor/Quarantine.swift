import Foundation

/// The `com.apple.quarantine` value Drop writes, derived from the DMG's own.
///
/// The value is `flags;timestamp;agent;uuid…`, with `flags` as 4 hex digits. Drop changes
/// only the flags and keeps every other field byte for byte, so Gatekeeper still sees
/// who downloaded the image and when. See `gatekeeper-spike.md` and `preapproved-spike.md`.
public enum Quarantine {
    /// The xattr's name.
    public static let attributeName = "com.apple.quarantine"
    /// "Do not translocate": what a Finder move sets. Without it Drop's copies run from a
    /// randomised read-only path on every launch. Inferred from behaviour on macOS 27.
    public static let doNotTranslocateFlag: UInt16 = 0x0100
    /// "User approved": what clicking Open in the first-launch prompt sets. Only for apps
    /// the Verifier confirmed as notarized, and only when the user's setting is on.
    public static let userApprovedFlag: UInt16 = 0x0040

    private static let flagsDigits = 4
    private static let separator: Character = ";"

    /// `raw` with `flags` OR'ed into its flags field and every other field unchanged.
    ///
    /// Throws `ExtractorError.invalidQuarantine` when the first field isn't 4 hex digits:
    /// Drop never guesses at a value it doesn't understand.
    public static func adding(_ flags: UInt16, to raw: String) throws -> String {
        let field = raw.prefix { $0 != separator }
        guard field.count == flagsDigits, field.allSatisfy(\.isHexDigit), let current = UInt16(field, radix: 16)
        else { throw ExtractorError.invalidQuarantine(raw) }
        let hex = String(current | flags, radix: 16)
        return String(repeating: "0", count: flagsDigits - hex.count) + hex + raw.dropFirst(field.count)
    }

    /// The value staged items get: the DMG's value plus `doNotTranslocateFlag`.
    public static func staged(from dmgValue: String) throws -> String {
        try adding(doNotTranslocateFlag, to: dmgValue)
    }

    /// Reads `com.apple.quarantine` from a file, such as the downloaded DMG, without
    /// following a final symlink. Nil when it has none.
    public static func read(at url: URL) throws -> String? {
        let path = url.path
        let options = XATTR_NOFOLLOW
        let size = getxattr(path, attributeName, nil, 0, 0, options)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw ExtractorError.io(errno: errno, operation: "getxattr", path: path)
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let got = getxattr(path, attributeName, &bytes, size, 0, options)
        guard got >= 0 else { throw ExtractorError.io(errno: errno, operation: "getxattr", path: path) }
        return String(decoding: bytes.prefix(got), as: UTF8.self)
    }
}
