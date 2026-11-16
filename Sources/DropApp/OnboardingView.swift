import AppKit
import Onboarding
import SwiftUI

/// First-launch onboarding: five pages, one window (boards Onboarding1 to Onboarding5).
/// Each request runs only from its own button, through `OnboardingCoordinator`.
struct OnboardingView: View {
    let coordinator: OnboardingCoordinator
    /// The folder Allow Downloads lists: `--watch` in tests, else the one in Settings.
    let folder: () -> URL
    /// Choose another folder: an open panel, nil when cancelled.
    let chooseFolder: () -> URL?
    let openPrivacySettings: () -> Void
    /// Esc: closes the window, which `OnboardingWindowController` reports as closed early.
    let close: () -> Void
    /// The window's real title bar height, read from the window. The boards' band is taller,
    /// so this only matters if a future macOS makes the title bar taller than the band.
    var titleBarHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(Theme.Onboarding.titleBand, titleBarHeight))
            ZStack {
                page
                    .id(coordinator.page)
                    .transition(pageTransition)
            }
            .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.page, value: coordinator.page)
            .frame(maxHeight: .infinity)
            footer
                .padding([.horizontal, .bottom], Theme.onboardingInset)
        }
        .frame(width: Theme.Onboarding.width, height: Theme.Onboarding.height)
        .ignoresSafeArea()
        .background(SurfaceBackground(kind: .window).ignoresSafeArea())
        .background(shortcuts)
    }

    /// The old page blurs and fades out (blur 8, 0.35 s); the new one's elements blur in one
    /// after another (`staggeredBlurIn`). Reduce Motion: a cross-fade.
    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .opacity, removal: .blurFade(radius: Theme.Motion.pageBlur, offsetY: 0))
    }

    private var page: some View {
        VStack(spacing: 0) {
            OnboardingArt(page: coordinator.page)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Onboarding.artHeight)
                .background(
                    ArtBackground(), in: RoundedRectangle(cornerRadius: Theme.Onboarding.artCornerRadius)
                )
                .padding(.horizontal, Theme.onboardingInset)
                .accessibilityHidden(true)
                .staggeredBlurIn(0)
            text
                .padding(.top, Theme.Onboarding.textTopPadding)
                .padding(.horizontal, Theme.Onboarding.textHorizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Text

    private var text: some View {
        VStack(spacing: Theme.Onboarding.textSpacing) {
            Text(content.title)
                .font(Typeface.font(size: Theme.Onboarding.titleSize, weight: Theme.Onboarding.titleWeight))
                .tracking(Theme.Onboarding.titleTracking)
                .foregroundStyle(Theme.Colour.bodyText)
                .accessibilityAddTraits(.isHeader)
                .staggeredBlurIn(1)
            Text(content.body)
                .font(Theme.Font.body)
                .lineSpacing(Theme.Onboarding.bodyLineSpacing)
                .padding(.vertical, Theme.Onboarding.bodyLineSpacing / 2)
                .foregroundStyle(Theme.Colour.bodyText)
                .frame(maxWidth: Theme.Onboarding.bodyMaxWidth)
                .staggeredBlurIn(2)
            if coordinator.showsFolderDenied {
                denied.staggeredBlurIn(3)
            } else if let info = content.info {
                Label {
                    Text(info)
                } icon: {
                    Image(systemName: "info.circle").font(.system(size: Theme.Onboarding.infoIcon))
                }
                .labelStyle(InfoLabelStyle())
                .padding(.top, Theme.Onboarding.infoTopPadding)
                .staggeredBlurIn(3)
            }
            if coordinator.page == .done {
                Text("A Nidus Labs app. A home for little ideas.")
                    .font(Typeface.font(size: Theme.Onboarding.bylineSize, weight: .regular))
                    .foregroundStyle(Theme.Colour.secondaryText)
                    .padding(.top, Theme.Onboarding.bylineTopPadding)
                    .staggeredBlurIn(3)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Downloads was denied: what that means and where to change it.
    private var denied: some View {
        VStack(spacing: Theme.Onboarding.infoIconSpacing) {
            Text(
                "Drop needs this to see new downloads. You can allow it in System Settings \u{203A} Privacy & Security \u{203A} Files and Folders."
            )
            .font(Theme.Onboarding.infoFont)
            .foregroundStyle(Theme.Colour.secondaryText)
            .frame(maxWidth: Theme.Onboarding.bodyMaxWidth)
            Button("Open System Settings", action: openPrivacySettings)
                .buttonStyle(.nidusLink(font: Theme.Onboarding.infoFont))
        }
        .padding(.top, Theme.Onboarding.infoTopPadding)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Onboarding.footerSpacing) {
            PageDots(page: coordinator.page)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Button.spacing) { buttons }
                .disabled(coordinator.isBusy)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch coordinator.page {
        case .welcome:
            primary("Get Started") { coordinator.getStarted() }
        case .downloads:
            Button("Choose another folder") {
                if let url = chooseFolder() { coordinator.useFolder(url) }
            }
            .buttonStyle(.nidusLink(font: Theme.Onboarding.linkFont))
            .padding(.horizontal, Theme.Onboarding.linkPadding)
            if coordinator.showsFolderDenied {
                Button("Continue anyway") { coordinator.continueWithoutFolder() }
                    .buttonStyle(.nidusSecondary)
            }
            primary("Allow Downloads") {
                let folder = folder()
                Task { await coordinator.allowFolder(folder) }
            }
        case .diskImages:
            Button("Not now") { coordinator.skipDefaultHandler() }.buttonStyle(.nidusSecondary)
            primary("Use Drop") { Task { await coordinator.useDrop() } }
        case .loginItem:
            Button("Not now") { coordinator.skipLoginItem() }.buttonStyle(.nidusSecondary)
            primary("Start at Login") { coordinator.startAtLogin() }
        case .done:
            primary("Done") { coordinator.finish() }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.nidusPrimary)
            .keyboardShortcut(.defaultAction)
    }

    /// Esc closes and the left arrow goes back a page (there is no Back button). Zero-size
    /// buttons, because a keyboard shortcut needs a button in the window.
    private var shortcuts: some View {
        ZStack {
            Button("Close", action: close).keyboardShortcut(.cancelAction)
            Button("Back") { coordinator.goBack() }.keyboardShortcut(.leftArrow, modifiers: [])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Copy

    private struct Content {
        let title: String
        let body: String
        let info: String?
    }

    private var content: Content {
        switch coordinator.page {
        case .welcome:
            Content(
                title: "Install apps without the drag",
                body:
                    "Drop opens new disk images for you, shows who made the app, and puts it in Applications. No mounting, no ejecting.",
                info: nil)
        case .downloads:
            Content(
                title: "Drop watches your Downloads",
                body:
                    "When a disk image finishes downloading, a small panel slides in at the top right. Click Install and you\u{2019}re done.",
                info: "macOS will ask you to let Drop read your Downloads folder.")
        case .diskImages:
            Content(
                title: "Open disk images with Drop?",
                body:
                    "Double-click any .dmg and Drop installs it. You can still open an image the usual way from the panel.",
                info: "macOS will ask you to confirm. You can change this in Settings.")
        case .loginItem:
            Content(
                title: "Start Drop when you log in?",
                body:
                    "Drop runs quietly in the background, with no Dock icon. It only shows up when a disk image arrives.",
                info: "macOS will show that a background item was added.")
        case .done:
            Content(
                title: "You\u{2019}re all set",
                body:
                    "Drop stays out of sight until a disk image arrives. Open Drop again any time to change Settings.",
                info: nil)
        }
    }
}

/// The small grey line under the body: an info icon and one sentence.
private struct InfoLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Onboarding.infoIconSpacing) {
            configuration.icon
            configuration.title
        }
        .font(Theme.Onboarding.infoFont)
        .foregroundStyle(Theme.Colour.secondaryText)
    }
}

/// Five dots, the current one a wider accent pill.
private struct PageDots: View {
    let page: OnboardingPage

    var body: some View {
        HStack(spacing: Theme.Onboarding.dotSpacing) {
            ForEach(OnboardingPage.allCases, id: \.self) { dot in
                Capsule()
                    .fill(dot == page ? Theme.Colour.accent : Color.primary.opacity(Theme.Onboarding.mutedOpacity))
                    .frame(
                        width: dot == page ? Theme.Onboarding.activeDotWidth : Theme.Onboarding.dot,
                        height: Theme.Onboarding.dot)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(page.rawValue) of \(OnboardingPage.allCases.count)")
    }
}

/// The illustration panel's fill: the boards' `#F5F5F7`, as the tinted-card fill.
private struct ArtBackground: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        Theme.Colour.infoFill
    }
}

// MARK: Illustrations

/// One drawing per page, after the boards' SVGs.
private struct OnboardingArt: View {
    let page: OnboardingPage

    var body: some View {
        switch page {
        case .welcome:
            HStack(spacing: Theme.Onboarding.Art.rowSpacing) {
                DiskImageGlyph(size: Theme.Onboarding.Art.diskImage)
                ArrowShape()
                    .stroke(
                        Theme.Colour.accent,
                        style: StrokeStyle(
                            lineWidth: Theme.Onboarding.Art.arrowStroke, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: Theme.Onboarding.Art.arrowWidth, height: Theme.Onboarding.Art.arrowHeight)
                ApplicationsFolder(size: Theme.Onboarding.Art.diskImage)
            }
        case .downloads: ScreenCornerArt()
        case .diskImages: BadgedDiskImage()
        case .loginItem: LoginItemsArt()
        case .done:
            DrawnCheck(lineWidth: Theme.Onboarding.Art.checkStroke)
                .frame(width: Theme.Onboarding.Art.check, height: Theme.Onboarding.Art.check)
        }
    }
}

/// Draws a path given in the boards' 72-unit (or other) SVG box, scaled to the frame.
private struct BoardPath: Shape {
    let box: CGSize
    let build: @Sendable (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var path = Path()
        build(&path)
        return path.applying(CGAffineTransform(scaleX: rect.width / box.width, y: rect.height / box.height))
    }
}

/// The boards' SVG box for the disk image and folder drawings.
private let glyphBox = CGSize(width: 72, height: 72)

/// A disk image: a rounded drive with "DMG" on it.
private struct DiskImageGlyph: View {
    let size: CGFloat
    private var scale: CGFloat { size / glyphBox.width }

    var body: some View {
        ZStack {
            let body = BoardPath(box: glyphBox) {
                $0.addRoundedRect(
                    in: CGRect(x: 10, y: 14, width: 52, height: 44), cornerSize: CGSize(width: 10, height: 10))
            }
            body.fill(Theme.Colour.surface)
            body.stroke(Theme.Colour.tertiaryText, lineWidth: Theme.Onboarding.Art.glyphStroke * scale)
            BoardPath(box: glyphBox) {
                $0.move(to: CGPoint(x: 10, y: 44))
                $0.addLine(to: CGPoint(x: 62, y: 44))
            }
            .stroke(Theme.Colour.tertiaryText, lineWidth: Theme.Onboarding.Art.glyphStroke * scale)
            BoardPath(box: glyphBox) {
                $0.addEllipse(in: CGRect(x: 49.5, y: 48.5, width: 5, height: 5))
            }
            .fill(Theme.Colour.secondaryText)
            Text("DMG")
                .font(Theme.Onboarding.Art.diskImageLabel)
                .scaleEffect(scale)
                .foregroundStyle(Theme.Colour.secondaryText)
                .position(x: 36 * scale, y: 30 * scale)
        }
        .frame(width: size, height: size)
    }
}

/// The Applications folder: a blue folder with the "A" mark.
private struct ApplicationsFolder: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            BoardPath(box: glyphBox) {
                $0.move(to: CGPoint(x: 8, y: 22))
                $0.addArc(tangent1End: CGPoint(x: 8, y: 17), tangent2End: CGPoint(x: 13, y: 17), radius: 5)
                $0.addLine(to: CGPoint(x: 28, y: 17))
                $0.addLine(to: CGPoint(x: 33, y: 22))
                $0.addLine(to: CGPoint(x: 59, y: 22))
                $0.addArc(tangent1End: CGPoint(x: 64, y: 22), tangent2End: CGPoint(x: 64, y: 27), radius: 5)
                $0.addLine(to: CGPoint(x: 64, y: 53))
                $0.addArc(tangent1End: CGPoint(x: 64, y: 58), tangent2End: CGPoint(x: 59, y: 58), radius: 5)
                $0.addLine(to: CGPoint(x: 13, y: 58))
                $0.addArc(tangent1End: CGPoint(x: 8, y: 58), tangent2End: CGPoint(x: 8, y: 53), radius: 5)
                $0.closeSubpath()
            }
            .fill(Self.back)
            BoardPath(box: glyphBox) {
                $0.move(to: CGPoint(x: 8, y: 28))
                $0.addLine(to: CGPoint(x: 64, y: 28))
                $0.addLine(to: CGPoint(x: 64, y: 53))
                $0.addArc(tangent1End: CGPoint(x: 64, y: 58), tangent2End: CGPoint(x: 59, y: 58), radius: 5)
                $0.addLine(to: CGPoint(x: 13, y: 58))
                $0.addArc(tangent1End: CGPoint(x: 8, y: 58), tangent2End: CGPoint(x: 8, y: 53), radius: 5)
                $0.closeSubpath()
            }
            .fill(Self.front)
            BoardPath(box: glyphBox) {
                // The "A" mark: apex up, feet down, and its crossbar (SwiftUI's y grows down).
                $0.move(to: CGPoint(x: 30, y: 46))
                $0.addLine(to: CGPoint(x: 36, y: 34))
                $0.addLine(to: CGPoint(x: 42, y: 46))
                $0.move(to: CGPoint(x: 32, y: 42))
                $0.addLine(to: CGPoint(x: 40, y: 42))
            }
            .stroke(
                Theme.Colour.onAccent,
                style: StrokeStyle(
                    lineWidth: Theme.Onboarding.Art.arrowStroke * size / glyphBox.width, lineCap: .round,
                    lineJoin: .round))
        }
        .frame(width: size, height: size)
    }

    /// The boards' `#6AA9F7` and `#8CC0FA`: system blue lightened, so it follows the system.
    private static let back = Color(nsColor: .systemBlue.blended(withFraction: 0.4, of: .white) ?? .systemBlue)
    private static let front = Color(nsColor: .systemBlue.blended(withFraction: 0.55, of: .white) ?? .systemBlue)
}

/// The arrow between the disk image and the folder, in the boards' 48×20 box.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        BoardPath(box: CGSize(width: 48, height: 20)) {
            $0.move(to: CGPoint(x: 2, y: 10))
            $0.addLine(to: CGPoint(x: 42, y: 10))
            $0.move(to: CGPoint(x: 34, y: 3))
            $0.addLine(to: CGPoint(x: 42, y: 10))
            $0.addLine(to: CGPoint(x: 34, y: 17))
        }
        .path(in: rect)
    }
}

/// Board 2: a screen's top right corner, with the popup there under the menu bar.
private struct ScreenCornerArt: View {
    private typealias Art = Theme.Onboarding.Art

    var body: some View {
        RoundedRectangle(cornerRadius: Art.screenRadius)
            .fill(Color.primary.opacity(Theme.Onboarding.faintOpacity))
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Colour.surface.opacity(Art.screenBarOpacity)).frame(height: Art.screenBar)
            }
            .overlay(alignment: .topTrailing) {
                popup
                    .padding(.top, Art.popupTop)
                    .padding(.trailing, Art.popupInset)
            }
            .clipShape(RoundedRectangle(cornerRadius: Art.screenRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Art.screenRadius)
                    .strokeBorder(Color.primary.opacity(Theme.Onboarding.rowDividerOpacity), lineWidth: Art.lineWidth)
            }
            .frame(width: Art.screenWidth, height: Art.screenHeight)
    }

    private var popup: some View {
        HStack(spacing: Art.panelSpacing) {
            RoundedRectangle(cornerRadius: Art.panelTileRadius)
                .fill(Art.sampleAppTile)
                .frame(width: Art.panelTile, height: Art.panelTile)
            VStack(alignment: .leading, spacing: Art.panelLineSpacing) {
                Capsule().fill(Theme.Colour.bodyText).frame(width: Art.panelTitleWidth, height: Art.bar)
                Capsule().fill(Theme.Colour.tertiaryText).frame(width: Art.panelSubtitleWidth, height: Art.thinBar)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(Theme.Colour.accent)
                .frame(width: Art.panelButtonWidth, height: Art.panelButtonHeight)
        }
        .padding(Art.panelPadding)
        .frame(width: Art.panelWidth)
        .background(card(radius: Art.panelRadius))
        .shadow(
            color: .black.opacity(Theme.Onboarding.shadowOpacity), radius: Theme.Onboarding.shadowRadius,
            y: Theme.Onboarding.shadowY)
    }
}

/// A white card with the boards' hairline border.
private func card(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius)
        .fill(Theme.Colour.surface)
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.primary.opacity(Theme.Onboarding.hairlineOpacity))
        }
}

/// Board 3: the disk image with Drop's badge.
private struct BadgedDiskImage: View {
    private typealias Art = Theme.Onboarding.Art

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DiskImageGlyph(size: Art.largeDiskImage)
                .frame(width: Art.badgeFrame, height: Art.badgeFrame)
            Circle()
                .fill(Theme.Colour.accent)
                .overlay {
                    Image(systemName: "drop")
                        .font(.system(size: Art.badgeGlyph, weight: .bold))
                        .foregroundStyle(Theme.Colour.onAccent)
                }
                .frame(width: Art.badge, height: Art.badge)
                .padding(Art.badgeBorder)
                .background(Circle().fill(ArtRing()))
                .padding(.trailing, Art.badgeTrailing)
                .padding(.bottom, Art.badgeBottom)
        }
        .frame(width: Art.badgeFrame, height: Art.badgeFrame)
    }
}

/// The badge's border is the illustration panel's colour over the window, so it reads as a
/// cut-out in both modes.
private struct ArtRing: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        Theme.Colour.surface.mix(
            with: .primary,
            by: environment.colorScheme == .dark ? Theme.Card.darkFillOpacity : Theme.Card.fillOpacity)
    }
}

/// Board 4: two rows of System Settings' Login Items, Drop's switch on.
private struct LoginItemsArt: View {
    private typealias Art = Theme.Onboarding.Art

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Art.listRowSpacing) {
                RoundedRectangle(cornerRadius: Art.listIconRadius).fill(faint)
                    .frame(width: Art.listIcon, height: Art.listIcon)
                Capsule().fill(Color.primary.opacity(Theme.Onboarding.mutedOpacity))
                    .frame(width: Art.listLineWidth, height: Art.bar)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(faint).frame(width: Art.switchWidth, height: Art.switchHeight)
            }
            .padding(.vertical, Art.listRowPadding)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(Theme.Onboarding.rowDividerOpacity)).frame(height: 1)
            }
            HStack(spacing: Art.listRowSpacing) {
                RoundedRectangle(cornerRadius: Art.listIconRadius).fill(Theme.Colour.bodyText)
                    .frame(width: Art.listIcon, height: Art.listIcon)
                    .overlay {
                        Image(systemName: "drop")
                            .font(.system(size: Art.listIconGlyph, weight: .bold))
                            .foregroundStyle(Theme.Colour.surface)
                    }
                Text("Drop").font(Art.listNameFont).foregroundStyle(Theme.Colour.bodyText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(Theme.Colour.accent)
                    .frame(width: Art.switchWidth, height: Art.switchHeight)
                    .overlay(alignment: .trailing) {
                        Circle().fill(Theme.Colour.onAccent)
                            .frame(width: Art.switchKnob, height: Art.switchKnob)
                            .padding(.trailing, Art.switchInset)
                    }
            }
            .padding(.vertical, Art.listRowPadding)
        }
        .padding(.vertical, Art.listVerticalPadding)
        .padding(.horizontal, Art.listHorizontalPadding)
        .frame(width: Art.listWidth)
        .background(card(radius: Art.panelRadius))
    }

    private var faint: Color { Color.primary.opacity(Theme.Onboarding.faintOpacity) }
}

// MARK: Window

/// The onboarding window: centred, 600×480, a standard titled window with only the close
/// button enabled, not resizable. Closing it any way other than Done tells the coordinator
/// it was closed early.
///
/// While it's open Drop is a regular app, so it shows in Command-Tab (and, for that time,
/// in the Dock), and the window floats above other apps' windows so it isn't lost behind
/// them. macOS's own prompts (the folder access alert, the default-app confirmation) come
/// from other processes; while a request is running the window drops to the normal level,
/// so a prompt can never open underneath it. When onboarding ends Drop goes back to an
/// accessory app with no Dock icon.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let coordinator: OnboardingCoordinator
    private let makeView: (_ close: @escaping () -> Void) -> OnboardingView

    init(coordinator: OnboardingCoordinator, makeView: @escaping (_ close: @escaping () -> Void) -> OnboardingView) {
        self.coordinator = coordinator
        self.makeView = makeView
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var windowNumber: Int? { window?.windowNumber }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: Theme.Onboarding.width, height: Theme.Onboarding.height),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            var view = makeView { [weak self] in self?.window?.performClose(nil) }
            view.titleBarHeight = window.frame.height - window.contentLayoutRect.height
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setContentSize(NSSize(width: Theme.Onboarding.width, height: Theme.Onboarding.height))
            window.title = "Welcome to Drop"
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.paintsSurfaceUnderTitleBar()
            window.delegate = self
            window.center()
            self.window = window
            followRequests()
        }
        NSApp.setActivationPolicy(.regular)
        window?.level = coordinator.isBusy ? .normal : .floating
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closes after Done; `windowWillClose` then sees onboarding complete and does nothing.
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.level = .normal
        NSApp.setActivationPolicy(.accessory)
        coordinator.windowClosed()
    }

    /// Normal level while a request (and so possibly a macOS prompt) is running, floating
    /// otherwise.
    private func followRequests() {
        withObservationTracking {
            _ = coordinator.isBusy
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let window = self.window, window.isVisible else { return }
                window.level = self.coordinator.isBusy ? .normal : .floating
                self.followRequests()
            }
        }
    }
}
