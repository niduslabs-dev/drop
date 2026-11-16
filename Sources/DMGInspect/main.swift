import DMGReader
import Foundation

/// `dmg-inspect <file.dmg> [--tree]`: what Drop sees in a disk image, without mounting it.
/// For debugging the reader against real downloads.
let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: dmg-inspect <file.dmg> [--tree]\n".utf8))
    exit(64)
}
let showTree = arguments.contains("--tree")

do {
    let start = Date()
    let opened = try DMGReader.open(path: path)
    let openTime = Date().timeIntervalSince(start)

    print("container:   \(opened.image.container)")
    if let udif = opened.image.udif {
        let kinds = Dictionary(grouping: udif.chunks, by: { "\($0.type)" }).mapValues(\.count)
        print("chunks:      \(udif.chunks.count) \(kinds.sorted { $0.key < $1.key })")
    }
    print("partition:   \(opened.location.partition.map { "\($0.name) at \($0.start)" } ?? "none")")
    print("filesystem:  \(opened.fileSystem.kind) \"\(opened.fileSystem.volumeName)\"")
    print("licence:     \(opened.image.licence.map { "\($0.languages.count) language(s)" } ?? "none")")
    print("signed:      \(opened.image.codeSignature != nil ? "yes" : "no")")
    print("apps:        \(try opened.apps().map(\.name))")
    let packages = try opened.packages().map(\.name)
    if !packages.isEmpty { print("packages:    \(packages)") }

    var counts = (files: 0, directories: 0, symlinks: 0, compressed: 0, bytes: UInt64(0))
    try DMGReader.walk(opened.fileSystem) { components, entry in
        switch entry.kind {
        case .file: counts.files += 1
        case .directory: counts.directories += 1
        case .symlink: counts.symlinks += 1
        case .other: break
        }
        if entry.isCompressed { counts.compressed += 1 }
        counts.bytes += entry.size
        if showTree { print("  \(components.joined(separator: "/"))\(entry.kind == .directory ? "/" : "")") }
    }
    print(
        "contents:    \(counts.files) files, \(counts.directories) folders, \(counts.symlinks) symlinks, "
            + "\(counts.bytes / 1_000_000) MB, \(counts.compressed) compressed")
    print(String(format: "opened in:   %.3f s; walked in %.3f s", openTime, Date().timeIntervalSince(start) - openTime))
} catch let error as ReaderError {
    print("error: \(error)\(error.wantsMountFallback ? " (would use the hidden-mount fallback)" : "")")
    exit(1)
} catch {
    print("error: \(error)")
    exit(1)
}
