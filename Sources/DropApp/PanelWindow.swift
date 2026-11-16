import AppKit
import SwiftUI

/// A floating panel that never activates Drop, so whatever the user is typing into keeps
/// focus. It may still become key (without activating) when the password field needs it.
final class DropPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        title = "Drop"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows one `PanelModel` at a time, anchored under the menu bar icon or at the top right.
@MainActor
final class PanelWindowController {
    private let panel = DropPanel()
    private var hosting: NSHostingView<AnyView>?
    /// Returns the icon's frame on screen, or nil when it has none to anchor to.
    private let anchor: () -> NSRect?
    private(set) var model: PanelModel?

    init(anchor: @escaping () -> NSRect?) {
        self.anchor = anchor
    }

    var windowNumber: Int { panel.windowNumber }
    var isVisible: Bool { panel.isVisible }

    func show(_ model: PanelModel) {
        self.model = model
        let root = AnyView(
            PanelView(model: model)
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                    self?.resize(to: size)
                })
        if let hosting {
            hosting.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            panel.contentView = view
            hosting = view
        }
        resize(to: hosting?.fittingSize ?? .zero)
        if model.board == .password { panel.makeKey() }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        model = nil
    }

    /// Makes the panel key without activating Drop, for the password field.
    func focus() { panel.makeKey() }

    /// Keeps the top edge (and the anchor's right edge) fixed while the content grows or
    /// shrinks between boards.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let origin = Self.origin(for: size, anchor: anchor())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    /// Under the icon, right edges aligned, kept on its screen; or the top right of the
    /// main screen's visible area (below the menu bar, whatever its height).
    static func origin(for size: CGSize, anchor: NSRect?) -> NSPoint {
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let visible = screen.visibleFrame
            var x = anchor.maxX + Theme.Panel.screenMargin - size.width
            x = min(
                max(x, visible.minX + Theme.Panel.screenMargin), visible.maxX - Theme.Panel.screenMargin - size.width)
            let top = anchor.minY - Theme.Panel.screenGap
            return NSPoint(x: x, y: top - size.height)
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(
            x: visible.maxX - Theme.Panel.screenMargin - size.width,
            y: visible.maxY - Theme.Panel.screenGap - size.height)
    }
}
