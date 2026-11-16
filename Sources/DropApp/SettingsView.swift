import AppKit
import SwiftUI

/// The Settings board, as a grouped form so it reads like System Settings.
struct SettingsView: View {
    @Bindable var preferences: Preferences
    let recent: [RecentInstall]
    let changeFolder: () -> Void
    let setOpenAtLogin: (Bool) -> Void
    let setOpensDiskImages: (Bool) -> Void

    var body: some View {
        Form {
            Section("Watching") {
                Toggle("Ask when a new disk image arrives", isOn: $preferences.askOnNewImage)
                LabeledContent("Folder") {
                    HStack(spacing: Theme.Settings.rowSpacing) {
                        Label {
                            Text(FileManager.default.displayName(atPath: preferences.watchedFolder.path))
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(Theme.Colour.folder)
                        }
                        .foregroundStyle(Theme.Colour.bodyText)
                        Button(action: changeFolder) { Text("Change…").singleLineLabel() }.controlSize(.small)
                    }
                }
            }
            Section("Installing") {
                Picker("Install apps to", selection: $preferences.installLocation) {
                    ForEach(InstallLocation.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Move the disk image to the Trash", isOn: $preferences.trashImage)
                Toggle("Open the app when it's installed", isOn: $preferences.openAfterInstall)
                Toggle(isOn: $preferences.skipFirstOpenPrompt) {
                    Text("Skip the \u{201C}downloaded from the Internet\u{201D} prompt")
                    Text("Only for apps notarized by Apple.")
                }
            }
            Section {
                Toggle("Open Drop at login", isOn: loginBinding)
                Toggle(isOn: handlerBinding) {
                    Text("Open disk images with Drop")
                    Text("Double-click a .dmg to get the install panel.")
                }
                Toggle(isOn: $preferences.keepInMenuBar) {
                    Text("Keep in menu bar")
                    Text("Otherwise the icon shows only while Drop asks you something.")
                }
            } header: {
                Text("General")
            } footer: {
                Text("Drop checks the signature before it installs.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Colour.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Recent") {
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
                        .buttonStyle(LinkButtonStyle())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: Theme.Settings.width)
        .fixedSize(horizontal: false, vertical: true)
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
