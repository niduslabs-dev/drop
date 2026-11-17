import AppKit
import QuartzCore
import SwiftUI
import os

/// The popup a new download gets: a borderless, non-activating panel at the top right that
/// floats above other apps on every Space (and beside full-screen apps) and never activates
/// Drop, so whatever the user is typing into stays the active app. Clicking it makes it key
/// (still without activating Drop), so Tab, Space, Return and Esc then work in it.
final class PopupPanel: NSPanel {
    /// Esc while the panel is key.
    var onCancel: () -> Void = {}

    init() {
        super.init(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Our own slide and blur are the only motion; the system's zoom-in would double it.
        animationBehavior = .none
        isReleasedWhenClosed = false
        title = "Drop"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// The window an opened disk image gets (Open With, a double-click): a normal titled
/// window, centred, that activates Drop and takes focus like any app the user opens.
final class CentredPanelWindow: NSWindow {
    /// Esc, or the close button.
    var onCancel: () -> Void = {}

    init() {
        super.init(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        title = "Drop"
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        paintsSurfaceUnderTitleBar()
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func performClose(_ sender: Any?) { onCancel() }
}

extension NSWindow {
    /// Our SwiftUI surface paints the whole window, title bar band included: no title bar
    /// material or separator of its own, and a clear window background, so the band can't
    /// show a different colour from the content (light surface, or dark ink glass).
    func paintsSurfaceUnderTitleBar() {
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isOpaque = false
        backgroundColor = .clear
    }
}

/// Lets the first click on the popup press a button even though the panel isn't key yet.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows one `PanelModel` at a time: a watched download in the popup, an opened image in the
/// centred window. Both host the same `PanelView`.
@MainActor
final class PanelWindowController: NSObject, NSWindowDelegate {
    private let popup = PopupPanel()
    private let window = CentredPanelWindow()
    private var popupHosting: FirstMouseHostingView<AnyView>?
    private var windowHosting: NSHostingView<AnyView>?
    private var slide: FrameSlide?
    /// The popup is waiting for its first size before it slides in.
    private var entrancePending = false
    /// The centred window is waiting for its first size before it's placed and shown.
    private var windowPlacementPending = false
    private(set) var model: PanelModel?
    private var presentation: PanelPresentation?
    /// Counts shows, closes and exits, so an exit that finishes after the surface was
    /// shown again or closed knows to leave it alone.
    private var exitGeneration = 0
    /// The user asked to dismiss the shown model (Esc, or the window's close button).
    var onDismiss: (PanelModel) -> Void = { _ in }
    /// The popup or window was shown or closed: the update popup waits while either is up.
    var onVisibilityChange: () -> Void = {}

    override init() {
        super.init()
        window.delegate = self
        popup.onCancel = { [weak self] in self?.dismissShown() }
        window.onCancel = { [weak self] in self?.dismissShown() }
    }

    var windowNumber: Int { presentation == .window ? window.windowNumber : popup.windowNumber }
    /// The shown surface's frame on screen.
    var frame: NSRect { presentation == .window ? window.frame : popup.frame }
    /// The install window is up (not the popup).
    var isWindowVisible: Bool { window.isVisible }

    /// Brings the install window forward, for a click on the Dock icon.
    func bringWindowForward() {
        guard window.isVisible else { return }
        WindowPresence.present(window)
    }
    var isVisible: Bool { popup.isVisible || window.isVisible }
    /// A model is shown or about to be (its entrance can wait for the first size).
    var isShowingModel: Bool { model != nil }

    /// Shows `model`, or does nothing when it's already up (its boards update in place).
    func show(_ model: PanelModel) {
        guard self.model !== model else { return }
        resetExit()
        self.model = model
        switch model.origin {
        case .watched: showPopup(model)
        case .opened: showWindow(model)
        }
        onVisibilityChange()
    }

    func close() {
        entrancePending = false
        windowPlacementPending = false
        slide?.stop()
        slide = nil
        popup.orderOut(nil)
        window.orderOut(nil)
        resetExit()
        ActivationPolicy.closed(.install)
        // Drop the views, so their tasks and timers stop while nothing is shown.
        popupHosting?.rootView = AnyView(EmptyView())
        windowHosting?.rootView = AnyView(EmptyView())
        model = nil
        presentation = nil
        onVisibilityChange()
    }

    // MARK: Exit before the app opens

    /// Plays the shown surface's exit and orders it out, keeping its model and views: the
    /// install window fades and shrinks a little, the popup slides back off the edge it
    /// came from (Reduce Motion: a fade alone for both). Drop leaves the Dock as the
    /// window goes. Follow with `close()` once the app has opened, or `restoreHidden()`
    /// when it didn't.
    ///
    /// The window's frame never changes: the shrink is a transform on the content's
    /// layer, so nothing lays out again on the way out.
    ///
    /// - Returns: false when nothing is shown, or the surface was shown again or closed
    ///   while the exit ran; it's then left as it is.
    func hideForOpen() async -> Bool {
        guard model != nil, let presentation else { return false }
        exitGeneration += 1
        let generation = exitGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch presentation {
        case .window: await fadeOutWindow(reduceMotion: reduceMotion)
        case .popup: await slideOutPopup(reduceMotion: reduceMotion)
        }
        guard generation == exitGeneration else { return false }
        popup.orderOut(nil)
        window.orderOut(nil)
        clearExitEffects()
        ActivationPolicy.closed(.install)
        return true
    }

    /// Brings back the surface `hideForOpen` hid, on the board its model shows now: the
    /// window where it was, the popup with its entrance.
    func restoreHidden() {
        guard model != nil, let presentation, !isVisible else { return }
        resetExit()
        switch presentation {
        case .window:
            ActivationPolicy.opened(.install)
            WindowPresence.present(window)
        case .popup:
            // The size it left with: its content hasn't changed while it was hidden.
            guard let target = Self.popupFrame(for: popup.frame.size) else { return }
            beginEntrance(at: target)
        }
    }

    private func fadeOutWindow(reduceMotion: Bool) async {
        if !reduceMotion, let layer = windowHosting?.layer {
            // About the content's centre, wherever AppKit put the layer's anchor.
            let centre = CGPoint(
                x: (0.5 - layer.anchorPoint.x) * layer.bounds.width,
                y: (0.5 - layer.anchorPoint.y) * layer.bounds.height)
            var shrunk = CATransform3DMakeTranslation(centre.x, centre.y, 0)
            shrunk = CATransform3DScale(shrunk, Theme.Motion.windowExitScale, Theme.Motion.windowExitScale, 1)
            shrunk = CATransform3DTranslate(shrunk, -centre.x, -centre.y, 0)
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = CATransform3DIdentity
            shrink.toValue = shrunk
            shrink.duration = Theme.Motion.windowExitDuration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Held at the end until the window is ordered out, so it can't snap back to
            // full size for a frame.
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: Self.exitAnimationKey)
        }
        let window = window
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.windowExitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }
    }

    private func slideOutPopup(reduceMotion: Bool) async {
        slide?.stop()
        slide = nil
        entrancePending = false
        let popup = popup
        let off = popup.frame.offsetBy(dx: popup.frame.width + Theme.Popup.screenInset, dy: 0)
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.popupExitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            popup.animator().alphaValue = 0
            if !reduceMotion { popup.animator().setFrame(off, display: true) }
        }
    }

    /// Forgets an exit in flight and undoes its effects, before a surface shows again.
    private func resetExit() {
        exitGeneration += 1
        clearExitEffects()
    }

    private func clearExitEffects() {
        windowHosting?.layer?.removeAnimation(forKey: Self.exitAnimationKey)
        window.alphaValue = 1
        popup.alphaValue = 1
    }

    private static let exitAnimationKey = "dev.niduslabs.drop.exit"

    /// Makes the shown panel key without activating Drop, for the password field. Never in
    /// a background test: a key non-activating panel would take the user's keystrokes.
    func focus() {
        if presentation == .popup, !WindowPresence.isBackgroundTest { popup.makeKey() }
    }

    private func dismissShown() {
        guard let model else { return }
        onDismiss(model)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissShown()
        return false
    }

    // MARK: Popup

    private func showPopup(_ model: PanelModel) {
        if window.isVisible { window.orderOut(nil) }
        ActivationPolicy.closed(.install)
        presentation = .popup
        let root = AnyView(
            PanelView(model: model)
                .environment(\.panelPresentation, .popup)
                .modifier(PopupEntrance())
                .id(model.id)
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                    self?.resizePopup(to: size)
                }
                .displayOptions())
        let hosting: FirstMouseHostingView<AnyView>
        if let popupHosting {
            hosting = popupHosting
            hosting.rootView = root
        } else {
            hosting = FirstMouseHostingView(rootView: root)
            hosting.sizingOptions = []
            popup.contentView = hosting
            popupHosting = hosting
        }
        slide?.stop()
        slide = nil
        // The first size can arrive after this, from the content's geometry; the entrance
        // waits for it.
        entrancePending = true
        resizePopup(to: hosting.fittingSize)
    }

    /// Orders the popup in at `target`: sliding in on the spring, or fading in with Reduce
    /// Motion.
    private func beginEntrance(at target: NSRect) {
        entrancePending = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            popup.setFrame(target, display: true)
            popup.alphaValue = 0
            WindowPresence.presentWithoutFocus(popup)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.fadeDuration
                popup.animator().alphaValue = 1
            }
        } else {
            popup.alphaValue = 1
            let slide = FrameSlide(window: popup, target: target, offset: target.width + Theme.Popup.screenInset)
            slide.start()
            WindowPresence.presentWithoutFocus(popup)
            self.slide = slide
        }
        popup.invalidateShadow()
        if let model { Log.panel.info("panel ordered front \(model.dmg.lastPathComponent, privacy: .public)") }
    }

    private func resizePopup(to size: CGSize) {
        guard presentation == .popup, let target = Self.popupFrame(for: size) else { return }
        if entrancePending {
            beginEntrance(at: target)
        } else if let slide, slide.isRunning {
            slide.target = target
        } else {
            popup.setFrame(target, display: true)
        }
        popup.invalidateShadow()
    }

    /// The top right of the screen with the active menu bar, inside its visible frame (so
    /// below the menu bar whatever its height, and clear of a Dock on the right).
    ///
    /// `NSScreen.main` is the screen of the key window, and when Drop has none (it never
    /// activates for the popup) AppKit reports the screen whose menu bar is active: the one
    /// the user is working on, which is where a notification would appear too. The screen
    /// under the pointer was the alternative; it's wrong when the user types on one display
    /// and the pointer rests on another.
    static func popupFrame(for size: CGSize) -> NSRect? {
        guard size.width > 0, size.height > 0, let screen = NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - Theme.Popup.screenInset - size.width,
            y: visible.maxY - Theme.Popup.screenInset - size.height, width: size.width, height: size.height)
    }

    // MARK: Centred window

    private func showWindow(_ model: PanelModel) {
        if popup.isVisible { popup.orderOut(nil) }
        slide?.stop()
        slide = nil
        presentation = .window
        let titleBar = Self.titleBarHeight(for: window.styleMask)
        let root = AnyView(
            InstallWindowView(model: model)
                .environment(\.panelPresentation, .window)
                .environment(\.titleBarHeight, titleBar)
                .id(model.id)
                .fixedSize()
                // The board leaves room for the title bar itself and paints under it.
                .ignoresSafeArea()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                    self?.resizeWindow(to: size)
                }
                .displayOptions())
        let hosting: NSHostingView<AnyView>
        if let windowHosting {
            hosting = windowHosting
            hosting.rootView = root
        } else {
            hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            window.contentView = hosting
            windowHosting = hosting
        }
        windowPlacementPending = true
        resizeWindow(to: hosting.fittingSize)
    }

    /// The title bar's height for `styleMask`, from AppKit's own frame metrics (the window's
    /// layout rect isn't set until it has content).
    static func titleBarHeight(for styleMask: NSWindow.StyleMask) -> CGFloat {
        var plain = styleMask
        plain.remove(.fullSizeContentView)
        let content = NSRect(x: 0, y: 0, width: Theme.InstallWindow.width, height: Theme.InstallWindow.width)
        return NSWindow.frameRect(forContentRect: content, styleMask: plain).height - content.height
    }

    /// Centres the window on the active screen when it opens; later size changes (a board
    /// with more lines) keep its top edge and centre line where they are.
    private func resizeWindow(to size: CGSize) {
        guard presentation == .window, size.width > 0, size.height > 0 else { return }
        // Full-size content: the content view is the whole window, title bar included, and
        // the board already leaves room for the title bar at its top.
        var frame = NSRect(origin: .zero, size: size)
        if windowPlacementPending, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        } else {
            let old = window.frame
            frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
        if windowPlacementPending {
            windowPlacementPending = false
            ActivationPolicy.opened(.install)
            WindowPresence.present(window)
            if let model { Log.panel.info("panel ordered front \(model.dmg.lastPathComponent, privacy: .public)") }
        }
    }
}

/// Slides a window from `offset` points right of `target` into place on the popup spring
/// (response 0.4, damping 0.9), one step per display refresh. The target can move while it
/// runs (the content resizes as the board fills in). Also the update popup's entrance.
@MainActor
final class FrameSlide: NSObject {
    private weak var window: NSWindow?
    var target: NSRect
    private let offset: CGFloat
    private let spring = Spring(response: Theme.Motion.popupResponse, dampingRatio: Theme.Motion.popupDamping)
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    init(window: NSWindow, target: NSRect, offset: CGFloat) {
        self.window = window
        self.target = target
        self.offset = offset
    }

    var isRunning: Bool { link != nil }

    func start() {
        window?.setFrame(target.offsetBy(dx: offset, dy: 0), display: false)
        startTime = CACurrentMediaTime()
        // The screen's link, not the window's: the window starts off the screen's edge,
        // where it has no display to tick with.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let link = screen?.displayLink(target: self, selector: #selector(step(_:)))
        link?.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - startTime
        let progress = spring.value(target: 1.0, time: elapsed)
        let settled = elapsed >= spring.settlingDuration(target: 1.0, epsilon: Theme.Motion.settleEpsilon)
        let remaining = settled ? 0 : (1 - progress) * offset
        window?.setFrame(target.offsetBy(dx: remaining, dy: 0), display: true)
        if settled { stop() }
    }
}

extension Log {
    static let panel = Logger(subsystem: "dev.niduslabs.drop", category: "panel")
}
