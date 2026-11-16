import AppKit
import UniformTypeIdentifiers

/// "Open disk images with Drop": makes Drop (or Apple's DiskImageMounter again) the
/// default app for disk images. Drop always lists itself in Open With (Info.plist,
/// `LSHandlerRank` Alternate); this switch is the only thing that makes it the default.
///
/// The default lives in Launch Services, and the user can change it in Finder at any
/// time, so Drop never stores it: Settings reads the live value each time it opens.
@MainActor
enum DiskImageHandler {
    /// The disk image types Drop declares, as `mdls -name kMDItemContentType` reports them
    /// for `.dmg`, `.sparseimage` and `.sparsebundle`. Not the generic `com.apple.disk-image`
    /// parent: no other app claims it, so declaring it made Drop its default unasked.
    static let types: [UTType] = [
        "com.apple.disk-image-udif", "com.apple.disk-image-sparse", "com.apple.disk-image-sparse-bundle",
    ].compactMap { UTType($0) }

    static let diskImageMounter = URL(filePath: "/System/Library/CoreServices/DiskImageMounter.app")

    /// True when Drop opens every declared type by default.
    static var isDropDefault: Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        return types.allSatisfy {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL.path == me
        }
    }

    /// Sets Drop or DiskImageMounter as the default for every type. macOS asks the user to
    /// confirm; returns the real result afterwards, which may differ from what was asked.
    static func setDropDefault(_ on: Bool) async -> Bool {
        let app = on ? Bundle.main.bundleURL : diskImageMounter
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            } catch {
                Log.app.error(
                    "Couldn't set the default for \(type.identifier, privacy: .public): \(error, privacy: .public)")
            }
        }
        return isDropDefault
    }

    /// Opens a disk image with DiskImageMounter by name, never through the default app,
    /// so "Open disk image" can't loop back into Drop when Drop is the default.
    static func openWithMounter(_ url: URL) {
        NSWorkspace.shared.open(
            [url], withApplicationAt: diskImageMounter, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error { Log.app.error("DiskImageMounter didn't open it: \(error, privacy: .public)") }
        }
    }
}
