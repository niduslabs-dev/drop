import Foundation
import Synchronization

/// An encrypted image's password, held in a buffer Drop owns so it can be zeroed after
/// use (`wipe()`, and on deinit). It only ever reaches the attach tool through stdin: never
/// an argument, a log line or a `description`.
///
/// The `String` it is made from can't be zeroed (Swift strings are immutable and may be
/// copied); callers should drop theirs as soon as they have made this.
public final class MountPassword: Sendable, CustomStringConvertible {
    private let storage: Mutex<[UInt8]>

    public init(_ password: String) { storage = Mutex(Array(password.utf8)) }

    /// Takes the bytes and zeroes the caller's array.
    public init(bytes: inout [UInt8]) {
        storage = Mutex(bytes)
        Self.zero(&bytes)
    }

    deinit { wipe() }

    public var isEmpty: Bool { storage.withLock { $0.isEmpty } }

    /// Zeroes the bytes; the password is empty afterwards.
    public func wipe() {
        storage.withLock {
            Self.zero(&$0)
            $0.removeAll()
        }
    }

    func withBytes(_ body: (UnsafeRawBufferPointer) -> Void) {
        storage.withLock { bytes in bytes.withUnsafeBytes { body($0) } }
    }

    public var description: String { "MountPassword(redacted)" }

    private static func zero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}
