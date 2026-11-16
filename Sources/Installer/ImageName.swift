import Foundation

/// A readable app name from a disk image's file name, for the screens shown before Drop
/// can read the app itself (a locked image's password, a mount-only image's licence).
public enum ImageName {
    /// Words in a disk image's name that describe the build, not the app.
    static let buildWords: Set<String> = [
        "aarch64", "arm", "arm64", "x86", "x64", "x86_64", "amd64", "intel", "universal", "apple", "silicon",
        "mac", "macos", "osx", "darwin", "setup", "installer", "install", "latest", "release", "stable", "beta",
        "dmg", "for",
    ]

    /// "Linea-2.4.1.dmg" → "Linea", "Zed-aarch64.dmg" → "Zed", "Foo_v3_universal.dmg" → "Foo":
    /// the name up to the first word that is a version (starts with a digit, or v and a
    /// digit) or describes the build (`buildWords`). The whole name when nothing is left.
    public static func appName(fromImage url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        // A dotted version glued to the name, before the dots split it into words:
        // "Rectangle2.0.4" → "Rectangle".
        if let match = base.wholeMatch(of: /(.*?[A-Za-z])v?\d+(\.\d+)+/) { return String(match.1) }
        let separators: Set<Character> = ["-", "_", " ", "."]
        var cut = base.endIndex
        var wordStart = base.startIndex
        var index = base.startIndex
        while index <= base.endIndex {
            if index == base.endIndex || separators.contains(base[index]) {
                let word = base[wordStart..<index]
                if wordStart > base.startIndex, isBuildWord(word) {
                    cut = base.index(before: wordStart)
                    break
                }
                if index == base.endIndex { break }
                wordStart = base.index(after: index)
            }
            index = base.index(after: index)
        }
        let name = String(base[..<cut]).trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return name.isEmpty ? base : name
    }

    private static func isBuildWord(_ word: Substring) -> Bool {
        guard let first = word.first else { return false }
        if first.isNumber { return true }
        if first == "v" || first == "V", word.dropFirst().first?.isNumber == true { return true }
        return buildWords.contains(word.lowercased())
    }
}
