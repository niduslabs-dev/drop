import Foundation
import Onboarding
import ServiceManagement

/// Drop's first real access to the watched folder: opening and reading it. For
/// `~/Downloads` that makes macOS show its privacy prompt and blocks until the user
/// answers, so it runs off the main actor. A denied folder fails with `EPERM`.
struct ListingFolderAccess: FolderAccessChecking {
    func requestAccess(to folder: URL) async -> FolderAccessResult {
        let path = folder.path
        return await Task.detached(priority: .userInitiated) { Self.list(path) }.value
    }

    private static func list(_ path: String) -> FolderAccessResult {
        guard let directory = opendir(path) else { return result(errno) }
        defer { closedir(directory) }
        errno = 0
        if readdir(directory) == nil, errno != 0 { return result(errno) }
        return .granted
    }

    private static func result(_ code: Int32) -> FolderAccessResult {
        code == EPERM || code == EACCES ? .denied : .failed(code)
    }
}

/// Test launches without `--watch` would list the real `~/Downloads` (and so touch its
/// privacy grant), so they get this instead: it never touches the folder and says denied.
struct DeniedFolderAccess: FolderAccessChecking {
    func requestAccess(to folder: URL) async -> FolderAccessResult {
        Log.app.info("Test launch: folder access left alone, reported denied")
        return .denied
    }
}

/// Use Drop through `DiskImageHandler`, which macOS confirms with the user.
struct LiveDefaultHandler: DefaultHandlerSetting {
    func makeDropDefault() async -> Bool { await DiskImageHandler.setDropDefault(true) }
}

/// Start at Login through `SMAppService.mainApp`.
struct LiveLoginItem: LoginItemRegistering {
    func register() throws {
        try SMAppService.mainApp.register()
        Log.app.info("Login item on; status \(SMAppService.mainApp.status.rawValue)")
    }
}

/// Test launches leave the default handler and the login item alone, like the rest of
/// Drop's test mode: they log what they would have done and report the current state.
struct TestDefaultHandler: DefaultHandlerSetting {
    func makeDropDefault() async -> Bool {
        Log.app.info("Test launch: default handler left alone")
        return DiskImageHandler.isDropDefault
    }
}

struct TestLoginItem: LoginItemRegistering {
    func register() throws {
        Log.app.info("Test launch: login item left alone")
    }
}
