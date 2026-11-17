import AppKit
import SwiftUI

/// The Updates board's popup: "Drop 1.1 is ready", the version step and size, up to three
/// release-note lines, Release notes, Later and Restart to Update (Download before an
/// update is downloaded, when automatic installs are off). The same card as the install
/// popup (`PanelCard`), in the same top-right panel.
struct UpdatePopupView: View {
    let model: UpdateModel

    var body: some View {
        PanelCard {
            HStack(spacing: Theme.Header.spacing) {
                DropIcon(size: Theme.Header.appIcon)
                (Text("Drop").font(Theme.Font.captionStrong).foregroundStyle(Theme.Colour.bodyText)
                    + Text(" \u{00B7} Update").foregroundStyle(Theme.Colour.secondaryText))
                    .lineLimit(1)
            }
            .font(Theme.Font.caption)
            .accessibilityElement(children: .combine)
            HStack(spacing: Theme.Icon.titleSpacing) {
                DropIcon(size: Theme.Icon.size)
                VStack(alignment: .leading, spacing: Theme.Update.titleSpacing) {
                    Text(model.popupTitle).font(Theme.Font.title).tracking(Theme.Font.titleTracking)
                        .accessibilityAddTraits(.isHeader)
                    VersionStep(model: model).font(Theme.Font.subtitle)
                }
            }
            if let notes = model.update?.notes, !notes.isEmpty {
                NotesCard(lines: notes)
            }
            ButtonRow {
                if model.update?.releaseNotesURL != nil {
                    Button("Release notes") { model.openReleaseNotes() }.buttonStyle(.nidusLink())
                }
            } trailing: {
                Button("Later") { model.perform(.later) }.buttonStyle(.nidusSecondary)
                    .keyboardShortcut(.cancelAction)
                if case .available = model.phase {
                    Button("Download") { model.perform(.download) }.buttonStyle(.nidusPrimary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Restart to update") { model.perform(.restart) }.buttonStyle(.nidusPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, Theme.Panel.buttonRowTopPadding)
        }
    }
}

/// "1.0 → 1.1 · 4 MB, downloaded", the new version in the body colour.
private struct VersionStep: View {
    let model: UpdateModel

    var body: some View {
        let new = model.update?.version ?? ""
        let size = model.sizeDetail.map { " \u{00B7} \($0)" } ?? ""
        (Text("\(model.currentVersion) \u{2192} ").foregroundStyle(Theme.Colour.secondaryText)
            + Text(new).fontWeight(.semibold).foregroundStyle(Theme.Colour.bodyText)
            + Text(size).foregroundStyle(Theme.Colour.secondaryText))
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityLabel("\(model.currentVersion) to \(new)\(size)")
    }
}

/// The release-note lines as a bulleted list on the info fill.
private struct NotesCard: View {
    let lines: [String]

    var body: some View {
        InfoCard(spacing: Theme.Update.noteSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Update.bulletGap) {
                    Text("\u{2022}").accessibilityHidden(true)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(Theme.Colour.bodyText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lines.joined(separator: ". "))
    }
}

/// The banner at the top of Settings while an update waits for a restart: "Drop 1.1 is
/// ready", "Installs next time Drop quits, or now." and Restart to Update.
struct UpdateBanner: View {
    let model: UpdateModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        HStack(spacing: Theme.Update.bannerSpacing) {
            DropIcon(size: Theme.Update.bannerIcon)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.popupTitle).font(Theme.Font.calloutTitle).foregroundStyle(Theme.Colour.bodyText)
                Text("Installs next time Drop quits, or now.").font(Theme.Font.caption)
                    .foregroundStyle(Theme.Colour.secondaryText)
            }
            Spacer(minLength: 0)
            Button("Restart to update") { model.perform(.restart) }
                .buttonStyle(NidusButtonStyle(kind: .primary, size: .small))
        }
        .padding(.horizontal, Theme.Row.horizontalPadding)
        .padding(.vertical, Theme.Row.verticalPadding)
        .background(Theme.Colour.accent.opacity(Theme.Update.bannerFillOpacity), in: shape)
        .overlay { Hairline(shape: shape) }
        .accessibilityElement(children: .contain)
    }
}

/// The update popup's window: the same non-activating `PopupPanel` as an install popup, at
/// the same top-right spot. An install popup or window wins: while one is up the update
/// popup waits, and comes back when it closes.
@MainActor
final class UpdatePopupController {
    private let model: UpdateModel
    private let installPanel: PanelWindowController
    private let popup = PopupPanel()
    private var hosting: NSHostingView<AnyView>?
    private var slide: FrameSlide?

    init(model: UpdateModel, installPanel: PanelWindowController) {
        self.model = model
        self.installPanel = installPanel
        popup.title = "Drop Update"
        popup.onCancel = { [weak model] in model?.perform(.later) }
        observe()
    }

    var windowNumber: Int { popup.windowNumber }
    /// Shown, or waiting for its first size to slide in.
    private var isPresented = false
    private var entrancePending = false

    /// Shows or hides the popup to match the model and the install panel.
    func refresh() {
        let shows = model.wantsPopup && model.update != nil && !installPanel.isShowingModel
        if shows, !isPresented {
            present()
        } else if !shows, isPresented {
            isPresented = false
            entrancePending = false
            slide?.stop()
            slide = nil
            popup.orderOut(nil)
            hosting?.rootView = AnyView(EmptyView())
        }
    }

    private func observe() {
        withObservationTracking {
            _ = model.wantsPopup
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
    }

    /// Hosts the popup view; the entrance waits for SwiftUI's first size, as the install
    /// popup's does (`fittingSize` is zero until the content has laid out).
    private func present() {
        isPresented = true
        entrancePending = true
        let root = AnyView(
            UpdatePopupView(model: model)
                .environment(\.panelPresentation, .popup)
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in self?.resize(to: size) }
                .displayOptions())
        if let hosting {
            hosting.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            popup.contentView = hosting
            self.hosting = hosting
        }
        if let hosting { resize(to: hosting.fittingSize) }
    }

    private func resize(to size: CGSize) {
        guard isPresented, let frame = PanelWindowController.popupFrame(for: size) else { return }
        if entrancePending {
            entrancePending = false
            beginEntrance(at: frame)
        } else if let slide, slide.isRunning {
            slide.target = frame
        } else {
            popup.setFrame(frame, display: true)
        }
        popup.invalidateShadow()
    }

    /// The install popup's entrance: the spring slide from the right edge, or a fade with
    /// Reduce Motion.
    private func beginEntrance(at frame: NSRect) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            popup.setFrame(frame, display: true)
            popup.alphaValue = 0
            WindowPresence.presentWithoutFocus(popup)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.fadeDuration
                popup.animator().alphaValue = 1
            }
        } else {
            popup.alphaValue = 1
            let slide = FrameSlide(window: popup, target: frame, offset: frame.width + Theme.Popup.screenInset)
            slide.start()
            WindowPresence.presentWithoutFocus(popup)
            self.slide = slide
        }
        Log.updates.info("Update popup shown")
    }
}
