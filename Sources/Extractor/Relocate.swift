import Darwin
import Foundation

extension Extractor {
    /// Copies a staged app into a fresh staging area on `destinationDirectory`'s volume, for
    /// when the user picks a destination on another volume after staging: a rename can't
    /// cross volumes, and re-reading the image would re-stage, re-check and re-ask the licence.
    ///
    /// `copyfile` with `COPYFILE_ALL`, recursively and never following symlinks: data, modes,
    /// flags, times, ACLs and every xattr, so the stapled ticket comes along unchanged.
    /// `copyfile` rewrites the quarantine through libquarantine, which drops its time and
    /// agent, so each item's raw value is written back after the copy, flags
    /// (do-not-translocate, approved) and all. Folders are created owner-writable and get
    /// their real mode after their contents. Hard links become separate copies, which
    /// changes nothing the signature covers. The source is left as it is; the
    /// caller discards it once it has checked the copy. On any error, including
    /// cancellation (`ExtractorError.cancelled`), the new area is discarded.
    public static func copy(
        _ staged: StagedApp, toVolumeOf destinationDirectory: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> StagedApp {
        let area = try makeStagingArea(for: destinationDirectory)
        let target = area.url.appendingPathComponent(staged.name, isDirectory: true)
        do {
            try copyTree(from: staged.url.path, to: target.path, isCancelled: isCancelled)
            try copyQuarantine(from: staged.url.path, to: target.path)
            return StagedApp(url: target, area: area)
        } catch {
            discard(area)
            throw error
        }
    }

    private static func copyTree(from source: String, to target: String, isCancelled: @escaping @Sendable () -> Bool)
        throws
    {
        guard let state = copyfile_state_alloc() else {
            throw ExtractorError.io(errno: ENOMEM, operation: "copyfile_state_alloc", path: source)
        }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passRetained(CopyCancellation(isCancelled))
        defer { context.release() }
        let callback: copyfile_callback_t = { _, _, _, _, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let cancellation = Unmanaged<CopyCancellation>.fromOpaque(context).takeUnretainedValue()
            return cancellation.isCancelled() ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        // Both values are stored as given: the function pointer itself and the context pointer.
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context.toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)
        guard copyfile(source, target, state, flags) == 0 else {
            let error = errno
            if isCancelled() { throw ExtractorError.cancelled }
            throw ExtractorError.io(errno: error, operation: "copyfile", path: source)
        }
        if isCancelled() { throw ExtractorError.cancelled }
    }

    /// Writes each source item's raw `com.apple.quarantine` onto the same item of the copy.
    private static func copyQuarantine(from source: String, to target: String) throws {
        try forEachItem(under: source) { path in
            guard let value = try Quarantine.read(at: URL(fileURLWithPath: path)) else { return }
            let copy = target + path.dropFirst(source.count)
            try withOwnerWrite(copy) {
                let bytes = Array(value.utf8)
                let result = bytes.withUnsafeBytes {
                    setxattr(copy, Quarantine.attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
                guard result == 0 else { throw ExtractorError.io(errno: errno, operation: "setxattr", path: copy) }
            }
        }
    }
}

/// `copyfile`'s status callback context: the caller's cancellation check.
private final class CopyCancellation: Sendable {
    let isCancelled: @Sendable () -> Bool
    init(_ isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
}
