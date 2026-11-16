import Foundation
import Testing

@testable import Installer

/// The name shown before Drop can read the app (a locked or mount-only image): never the
/// raw file name with its version or build words.
struct ImageNameTests {
    @Test(arguments: [
        ("Linea-2.4.1.dmg", "Linea"),
        ("Zed-aarch64.dmg", "Zed"),
        ("Rectangle2.0.4.dmg", "Rectangle"),
        ("Foo_v3_universal.dmg", "Foo"),
        ("Visual Studio Code for Mac.dmg", "Visual Studio Code"),
        ("Firefox 120.0.dmg", "Firefox"),
        ("Vaultr-Setup.dmg", "Vaultr"),
        ("Arc-latest-arm64.dmg", "Arc"),
        ("obs-studio-30.1-macos-x86_64.dmg", "obs-studio"),
        ("Ledgerly-Pro.dmg", "Ledgerly-Pro"),
        ("1Password.dmg", "1Password"),
    ])
    func cleansTheFileName(file: String, expected: String) {
        #expect(ImageName.appName(fromImage: URL(filePath: "/tmp/\(file)")) == expected)
    }
}
