/// Why reading failed. Every case that isn't `corrupt` or `io` means "this image is
/// valid but Drop can't read it itself": the app sends it to the hidden-mount fallback.
public enum ReaderError: Error, Sendable, Equatable {
    // Fallback: valid but unsupported.
    case encrypted
    case sparseImage
    case unsupportedContainer(String)
    case unsupportedCompression(UInt32)
    case unsupportedPartitionScheme(String)
    case unsupportedFileSystem(String)
    case compressedFile(path: String)

    // Bad input.
    case corrupt(String)
    case outOfBounds
    case notADirectory
    case notASymlink
    case io(errno: Int32, context: String)

    /// True when the hidden-mount fallback should handle the image.
    public var wantsMountFallback: Bool {
        switch self {
        case .encrypted, .sparseImage, .unsupportedContainer, .unsupportedCompression,
            .unsupportedPartitionScheme, .unsupportedFileSystem, .compressedFile:
            true
        case .corrupt, .outOfBounds, .notADirectory, .notASymlink, .io:
            false
        }
    }
}
