import AppKit
import SwiftUI

/// The Settings board, as a grouped form so it reads like System Settings, with the kit's
/// switches, select and buttons. Pausing is the Ask switch; Quit Drop sits at the bottom,
/// since Drop has no menu bar menu.
struct SettingsView: View {
    @Bindable var preferences: Preferences
    let recent: [RecentInstall]
    let changeFolder: () -> Void
    let setOpenAtLogin: (Bool) -> Void
    let setOpensDiskImages: (Bool) -> Void
    let quit: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.askOnNewImage) {
                    Text("Ask when a new disk image arrives")
                    caption("Turn off to pause watching.")
                }
                HStack(spacing: Theme.Settings.rowSpacing) {
                    Text("Folder")
                    Spacer(minLength: 0)
                    HStack(spacing: Theme.Settings.rowSpacing) {
                        Label {
                            Text(FileManager.default.displayName(atPath: preferences.watchedFolder.path))
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(Theme.Colour.folder)
                        }
                        .foregroundStyle(Theme.Colour.bodyText)
                        Button("Change\u{2026}", action: changeFolder).buttonStyle(.nidusSmall)
                    }
                }
            } header: {
                header("Watching")
            }
            Section {
                HStack(spacing: Theme.Settings.rowSpacing) {
                    Text("Install apps to")
                    Spacer(minLength: 0)
                    NidusSelect(
                        label: "Install apps to", selection: preferences.installLocation,
                        options: InstallLocation.allCases, title: \.title
                    ) { preferences.installLocation = $0 }
                }
                Toggle("Move the disk image to the Trash", isOn: $preferences.trashImage)
                Toggle("Open the app when it's installed", isOn: $preferences.openAfterInstall)
                Toggle(isOn: $preferences.skipFirstOpenPrompt) {
                    Text("Skip the \u{201C}downloaded from the Internet\u{201D} prompt")
                    caption("Only for apps notarized by Apple.")
                }
            } header: {
                header("Installing")
            }
            Section {
                Toggle("Open Drop at login", isOn: loginBinding)
                Toggle(isOn: handlerBinding) {
                    Text("Open disk images with Drop")
                    caption("Double-click a .dmg to get the install panel.")
                }
            } header: {
                header("General")
            } footer: {
                caption("Drop checks the signature before it installs.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                if recent.isEmpty {
                    Text("Apps Drop installs show here.").foregroundStyle(Theme.Colour.secondaryText)
                }
                ForEach(recent) { install in
                    HStack(spacing: Theme.Settings.rowSpacing) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: install.path))
                            .resizable()
                            .frame(width: Theme.Icon.recentSize, height: Theme.Icon.recentSize)
                        Text(install.title)
                        Spacer()
                        Text(Format.relative(install.date)).font(Theme.Font.small)
                            .foregroundStyle(Theme.Colour.secondaryText)
                        Button("Show") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: install.path)])
                        }
                        .buttonStyle(.nidusLink())
                    }
                }
            } header: {
                header("Recent")
            } footer: {
                HStack {
                    Spacer()
                    Button("Quit Drop", action: quit).buttonStyle(.nidusSmall)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SurfaceBackground(kind: .settings).ignoresSafeArea())
        .toggleStyle(.nidusSwitch)
        .foregroundStyle(Theme.Colour.bodyText)
        .frame(width: Theme.Settings.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Section headers in the kit's secondary text, which clears 4.5:1 where the system's
    /// header grey doesn't at this size.
    private func header(_ title: String) -> some View {
        Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.Colour.secondaryText)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.Colour.secondaryText)
    }

    private var handlerBinding: Binding<Bool> {
        Binding(get: { preferences.opensDiskImages }, set: { setOpensDiskImages($0) })
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { preferences.openAtLogin },
            set: {
                preferences.openAtLogin = $0
                setOpenAtLogin($0)
            })
    }
}

/// The Settings window. Showing it is the one time Drop activates itself.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView
    /// Runs before each show, to refresh values that live outside Drop.
    private let onShow: () -> Void

    init(makeView: @escaping () -> AnyView, onShow: @escaping () -> Void = {}) {
        self.makeView = makeView
        self.onShow = onShow
    }

    var windowNumber: Int? { window?.windowNumber }

    func show() {
        onShow()
        if window == nil {
            let controller = NSHostingController(rootView: makeView())
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "Drop"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.paintsSurfaceUnderTitleBar()
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else if let controller = window?.contentViewController as? NSHostingController<AnyView> {
            controller.rootView = makeView()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
