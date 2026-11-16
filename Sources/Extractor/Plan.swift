import Foundation
import ReaderCore

/// One item to write, with its path relative to the staging folder (`Name.app/Contents/…`).
struct PlannedItem: Sendable {
    let path: String
    let entry: Entry
    let depth: Int
}

/// Everything `stage` will write, worked out before the first byte lands so a bad or
/// compressed image fails while the staging folder is still empty.
struct StagePlan: Sendable {
    /// Parents before children.
    var directories: [PlannedItem] = []
    var symlinks: [(item: PlannedItem, target: String)] = []
    /// One per distinct file; later names for the same hard-linked file are in `links`.
    var files: [PlannedItem] = []
    var links: [(existing: String, new: String)] = []
    var totalBytes: UInt64 = 0

    /// Deeper than any real app bundle; stops a directory loop in a damaged image.
    static let maxDepth = 256

    /// Walks `app` and checks every name and kind.
    ///
    /// Throws `ReaderError.corrupt` for unsafe names (empty, `.`, `..`, containing `/` or
    /// NUL), devices, sockets and FIFOs, a directory reached twice, and symlink targets
    /// with NUL; `ReaderError.compressedFile` with the item's path for decmpfs files.
    ///
    /// Then throws `ExtractorError.nameCollision` when two names in one folder would land
    /// on the same name under `rules`, before anything is written.
    static func make(app: Entry, from fileSystem: any FileSystem, rules: NameRules) throws -> StagePlan {
        guard app.kind == .directory else { throw ReaderError.corrupt("\(app.name) is not a folder") }
        var plan = StagePlan()
        var firstPathForFile: [UInt64: String] = [:]
        var seenDirectories: Set<UInt64> = []
        var collisions: [String] = []
        var stack: [PlannedItem] = [PlannedItem(path: try checkedName(app.name), entry: app, depth: 0)]
        while let item = stack.popLast() {
            let entry = item.entry
            switch entry.kind {
            case .directory:
                guard seenDirectories.insert(entry.id).inserted else {
                    throw ReaderError.corrupt("\(item.path) is a folder that appears twice")
                }
                guard item.depth < maxDepth else {
                    throw ReaderError.corrupt("folders nested deeper than \(maxDepth) at \(item.path)")
                }
                plan.directories.append(item)
                let children = try fileSystem.children(of: entry)
                for child in children.reversed() {
                    let path = item.path + "/" + (try checkedName(child.name))
                    stack.append(PlannedItem(path: path, entry: child, depth: item.depth + 1))
                }
                collisions += rules.collisions(among: children.map(\.name)).map { item.path + "/" + $0 }
            case .symlink:
                let target = try fileSystem.symlinkTarget(of: entry)
                guard !target.isEmpty, !target.utf8.contains(0) else {
                    throw ReaderError.corrupt("symlink \(item.path) has an empty or NUL-containing target")
                }
                plan.symlinks.append((item, target))
            case .file:
                if entry.isCompressed { throw ReaderError.compressedFile(path: item.path) }
                if entry.isHardLink, let existing = firstPathForFile[entry.id] {
                    plan.links.append((existing, item.path))
                    continue
                }
                if entry.isHardLink { firstPathForFile[entry.id] = item.path }
                plan.files.append(item)
                let (total, overflow) = plan.totalBytes.addingReportingOverflow(entry.size)
                guard !overflow else { throw ReaderError.corrupt("file sizes overflow") }
                plan.totalBytes = total
            case .other:
                throw ReaderError.corrupt("\(item.path) is a device, socket or FIFO")
            }
        }
        if !collisions.isEmpty {
            throw ExtractorError.nameCollision(
                paths: collisions.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
                volumeIsCaseSensitive: rules.caseSensitive)
        }
        return plan
    }

    /// The name, if it can only ever mean one item inside its parent folder.
    static func checkedName(_ name: String) throws -> String {
        let bytes = name.utf8
        guard !name.isEmpty, name != ".", name != "..", !bytes.contains(UInt8(ascii: "/")), !bytes.contains(0) else {
            throw ReaderError.corrupt("unsafe name \(name.debugDescription)")
        }
        return name
    }
}

/// How the staging volume decides that two names are the same file.
struct NameRules: Sendable {
    let caseSensitive: Bool

    /// The staging volume's rules, from `pathconf(_PC_CASE_SENSITIVE)` on a folder in it.
    /// When the volume won't say, it is taken as case-insensitive, which can only refuse
    /// more images, never overwrite a file. Every volume is treated as
    /// normalisation-insensitive: APFS (all variants since macOS 10.13) and HFS+ are, and
    /// an app holding both spellings of one name isn't worth the risk elsewhere.
    static func ofVolume(at path: String) -> NameRules {
        NameRules(caseSensitive: pathconf(path, _PC_CASE_SENSITIVE) == 1)
    }

    /// The form two names share exactly when the volume treats them as one: NFD, and
    /// case-folded on a case-insensitive volume. Compared as bytes.
    func key(_ name: String) -> [UInt8] {
        let folded = caseSensitive ? name : name.folding(options: [.caseInsensitive], locale: nil)
        return Array(folded.decomposedStringWithCanonicalMapping.utf8)
    }

    /// Every name in `names` that shares its key with another, in the given order.
    func collisions(among names: [String]) -> [String] {
        guard names.count > 1 else { return [] }
        var groups: [[UInt8]: [String]] = [:]
        for name in names { groups[key(name), default: []].append(name) }
        return names.filter { (groups[key($0)]?.count ?? 0) > 1 }
    }
}
