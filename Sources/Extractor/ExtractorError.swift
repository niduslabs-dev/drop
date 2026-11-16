import Foundation

/// Why staging or installing failed on the Mac's side. Problems with the image itself
/// come as `ReaderError` instead (including `compressedFile`, which sends the image to the
/// hidden-mount fallback).
public enum ExtractorError: Error, Sendable, Equatable {
    /// A system call failed. `path` is relative to the staging folder for items being
    /// written, absolute otherwise.
    case io(errno: Int32, operation: String, path: String)
    /// `StageOptions.isCancelled` returned true. The staging folder has been discarded.
    case cancelled
    /// The destination folder is missing (`ENOENT`), not a folder, or not writable by this user.
    case destinationNotWritable(path: String, errno: Int32)
    /// The DMG's `com.apple.quarantine` value doesn't start with a 4-hex-digit flags field.
    case invalidQuarantine(String)
    /// The new app is in place, but handing the old copy to `trash` failed. The old copy
    /// is still at `oldCopy`, inside the staging area; discard the area or retry.
    case trashFailed(oldCopy: String, reason: String)
    /// Names in one folder of the app that the staging volume would treat as the same
    /// name (differing only by case or Unicode normalisation on a case-insensitive
    /// volume, or only by normalisation on a case-sensitive one). `paths` are from the
    /// app's name down, sorted, every name of each colliding group. Nothing was written.
    case nameCollision(paths: [String], volumeIsCaseSensitive: Bool)
}
