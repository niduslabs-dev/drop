import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

// The Nidus component kit (Components.dc.html) as styles on real SwiftUI controls, so
// VoiceOver, keyboard shortcuts, dark mode and Increase Contrast keep working.
//
// Keyboard: every control here is focusable with Tab even when macOS Keyboard navigation
// is off (the design asks for it in onboarding, the popup and the centred window), shows
// the moss focus ring, and Space presses or toggles it. A standard `Button` only joins the
// key loop when Keyboard navigation is on, so the styles make the label focusable
// themselves with the `.edit` interaction, which macOS always lets Tab reach (as it does
// text fields), and draw their own ring.

extension View {
    /// Tab-focusable regardless of the Keyboard navigation setting, with Space running
    /// `onSpace`. The system focus effect is off; the caller draws `FocusRing`.
    func nidusFocusable(_ focused: FocusState<Bool>.Binding, enabled: Bool, onSpace: @escaping () -> Void)
        -> some View
    {
        focusable(enabled, interactions: .edit)
            .focused(focused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard enabled else { return .ignored }
                onSpace()
                return .handled
            }
    }

    /// A button label never wraps or truncates: the button grows to fit it, and the row
    /// around it makes room (`ButtonRow`).
    func singleLineLabel() -> some View {
        lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

/// The focusVisible behaviour: whether focus rings show. Hidden until the user presses a
/// keyboard focus key (Tab, Shift-Tab or an arrow), then shown while they keep using the
/// keyboard; any mouse click hides them again until the next such key. One value for the
/// whole app, fed by a local event monitor, so every window agrees.
@MainActor
@Observable
final class FocusVisibility {
    static let shared = FocusVisibility()

    private(set) var isVisible = false
    @ObservationIgnored private var monitor: Any?

    /// Tab, and the arrows, which move focus in lists and between buttons.
    private static let focusKeys: Set<UInt16> = Set(
        [kVK_Tab, kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow].map { UInt16($0) })

    /// Starts watching events. Called once at launch; later calls do nothing.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { event in
            MainActor.assumeIsolated {
                FocusVisibility.shared.observe(type: event.type, keyCode: event.type == .keyDown ? event.keyCode : 0)
            }
            return event
        }
    }

    /// Applies one event: a focus key shows rings, a click hides them. Other keys (Space,
    /// Return, typing) leave them as they are.
    func observe(type: NSEvent.EventType, keyCode: UInt16) {
        switch type {
        case .keyDown where Self.focusKeys.contains(keyCode):
            if !isVisible { isVisible = true }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isVisible { isVisible = false }
        default:
            break
        }
    }
}

/// The kit's focus ring: solid moss, 2 pt, 2 pt outside the control's shape. Drawn only
/// after keyboard use (`FocusVisibility`) and while the window is key: SwiftUI gives the
/// first control focus as soon as a window shows, and a ring the user didn't ask for would
/// suggest keys go there.
struct FocusRing<S: InsettableShape>: ViewModifier {
    let isFocused: Bool
    let shape: S
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let shown = isFocused && appearsActive && FocusVisibility.shared.isVisible
        content.overlay {
            shape.inset(by: -(Theme.Control.focusRingOffset + Theme.Control.focusRing / 2))
                .stroke(Theme.Colour.focusRing, lineWidth: Theme.Control.focusRing)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Buttons

/// Primary (moss capsule), secondary (paper capsule with a hairline), link (text) and
/// select (paper, radius 8). A `PrimitiveButtonStyle`, so it can trigger the button from
/// Space and draw its own pressed state; Return still reaches `.keyboardShortcut`.
struct NidusButtonStyle: PrimitiveButtonStyle {
    enum Kind {
        case primary
        case secondary
        case link(Color)
        case select
        /// The label as drawn, with only the press shade and the focus ring: disclosure rows
        /// and the ⓘ button.
        case plain
    }
    enum Size {
        case regular
        case small
        /// 240 × 38, for the install window and onboarding.
        case hero
    }

    var kind: Kind = .secondary
    var size: Size = .regular
    var font: Font?

    func makeBody(configuration: Configuration) -> some View {
        NidusButtonBody(configuration: configuration, kind: kind, size: size, font: font)
    }
}

extension PrimitiveButtonStyle where Self == NidusButtonStyle {
    static var nidusPrimary: NidusButtonStyle { NidusButtonStyle(kind: .primary) }
    static var nidusSecondary: NidusButtonStyle { NidusButtonStyle(kind: .secondary) }
    static var nidusSmall: NidusButtonStyle { NidusButtonStyle(kind: .secondary, size: .small) }
    static var nidusHeroPrimary: NidusButtonStyle { NidusButtonStyle(kind: .primary, size: .hero) }
    static var nidusHeroSecondary: NidusButtonStyle { NidusButtonStyle(kind: .secondary, size: .hero) }
    static var nidusPlain: NidusButtonStyle { NidusButtonStyle(kind: .plain) }
    static func nidusLink(_ colour: Color = Theme.Colour.link, font: Font = Theme.Font.link) -> NidusButtonStyle {
        NidusButtonStyle(kind: .link(colour), font: font)
    }
}

private struct NidusButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let kind: NidusButtonStyle.Kind
    let size: NidusButtonStyle.Size
    let font: Font?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var bounds = CGSize.zero
    @FocusState private var isFocused: Bool

    var body: some View {
        styled
            .contentShape(shape)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { bounds = $0 }
            .gesture(press, including: isEnabled ? .all : .none)
            .onHover { hovering in withAnimation(Theme.Motion.hover) { isHovered = hovering && isEnabled } }
            .modifier(FocusRing(isFocused: isFocused, shape: shape))
            .nidusFocusable($isFocused, enabled: isEnabled) { configuration.trigger() }
            .opacity(isEnabled ? 1 : Theme.Control.disabledOpacity)
            .animation(Theme.Motion.enable, value: isEnabled)
    }

    private var height: CGFloat {
        switch size {
        case .small: Theme.Button.smallHeight
        case .regular: Theme.Button.height
        case .hero: Theme.Button.heroHeight
        }
    }

    private var horizontalPadding: CGFloat { size == .small ? Theme.Button.smallPadding : Theme.Button.padding }

    /// Hero capsules are a fixed 240 wide; the others fit their label.
    private var heroWidth: CGFloat? { size == .hero ? Theme.Button.heroWidth : nil }

    private var shape: RoundedRectangle {
        switch kind {
        case .primary, .secondary: RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        case .link: RoundedRectangle(cornerRadius: Theme.Button.linkFocusRadius, style: .continuous)
        case .select, .plain: RoundedRectangle(cornerRadius: Theme.Control.cornerRadius, style: .continuous)
        }
    }

    @ViewBuilder private var styled: some View {
        let label = configuration.label.singleLineLabel()
        switch kind {
        case .primary:
            label
                .font(font ?? (size == .hero ? Theme.Font.heroPrimaryButton : Theme.Font.primaryButton))
                .foregroundStyle(Theme.Colour.onAccent)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: heroWidth, minHeight: height)
                .background(primaryFill, in: shape)
        case .secondary:
            label
                .font(font ?? (size == .hero ? Theme.Font.heroButton : Theme.Font.button))
                .foregroundStyle(Theme.Colour.bodyText)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: heroWidth, minHeight: height)
                .background(paper)
                .overlay { shape.strokeBorder(Theme.Colour.hairline, lineWidth: Theme.Button.hairline) }
        case .select:
            label
                .font(font ?? Theme.Font.body)
                .foregroundStyle(Theme.Colour.bodyText)
                .padding(.leading, Theme.Control.selectLeading)
                .padding(.trailing, Theme.Control.selectTrailing)
                .frame(minHeight: height)
                .background(paper)
                .overlay { shape.strokeBorder(Theme.Colour.hairline, lineWidth: Theme.Button.hairline) }
        case .link(let colour):
            label
                .font(font ?? Theme.Font.link)
                .foregroundStyle(isPressed ? Theme.Colour.accentPressed : colour)
                .underline(isHovered)
                .padding(.horizontal, Theme.Button.linkPadding)
        case .plain:
            // A row's own layout decides its width; only labels of capsules are kept on one line.
            configuration.label
                .background {
                    shape.fill(
                        Color.primary.opacity(
                            isPressed ? Theme.Button.pressShade : isHovered ? Theme.Button.hoverShade : 0))
                }
        }
    }

    private var primaryFill: Color {
        isPressed ? Theme.Colour.accentPressed : isHovered ? Theme.Colour.accentHover : Theme.Colour.accent
    }

    /// Paper with the board's hover and press shade over it.
    private var paper: some View {
        shape.fill(Theme.Colour.paper)
            .overlay {
                shape.fill(
                    Color.black.opacity(isPressed ? Theme.Button.pressShade : isHovered ? Theme.Button.hoverShade : 0))
            }
    }

    /// Presses on mouse down, triggers on mouse up inside, like a native button.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let inside = CGRect(origin: .zero, size: bounds).contains(value.location)
                if inside != isPressed { withAnimation(Theme.Motion.hover) { isPressed = inside } }
            }
            .onEnded { value in
                withAnimation(Theme.Motion.hover) { isPressed = false }
                if CGRect(origin: .zero, size: bounds).contains(value.location) { configuration.trigger() }
            }
    }
}

// MARK: - Toggles

/// The kit's switch (34 × 20, moss track, white knob): label on the left, switch on the
/// right. The whole row toggles on click; Space toggles it when focused. Drop has no
/// checkboxes; every on/off choice is this switch.
struct NidusSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        NidusSwitchBody(configuration: configuration)
    }
}

extension ToggleStyle where Self == NidusSwitchStyle {
    static var nidusSwitch: NidusSwitchStyle { NidusSwitchStyle() }
}

private struct NidusSwitchBody: View {
    let configuration: ToggleStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Control.switchLabelSpacing) {
            VStack(alignment: .leading, spacing: Theme.Control.captionSpacing) { configuration.label }
            Spacer(minLength: 0)
            track
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .nidusFocusable($isFocused, enabled: isEnabled) { toggle() }
        .opacity(isEnabled ? 1 : Theme.Control.disabledOpacity)
        .animation(Theme.Motion.enable, value: isEnabled)
        // One element named by the label's text, read as a switch with its state, and
        // toggled by VoiceOver's press like the native switch.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
        .accessibilityAction { toggle() }
    }

    private func toggle() {
        guard isEnabled else { return }
        withAnimation(reduceMotion ? nil : Theme.Motion.toggle) { configuration.isOn.toggle() }
    }

    private var track: some View {
        let shape = Capsule()
        return shape.fill(configuration.isOn ? Theme.Colour.accent : Theme.Colour.switchOff)
            .overlay {
                shape.strokeBorder(Theme.Colour.controlBoundary, lineWidth: Theme.Control.switchBorder)
                    .opacity(configuration.isOn ? 0 : 1)
            }
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(Color.white)
                    .shadow(
                        color: .black.opacity(Theme.Control.knobShadowOpacity), radius: Theme.Control.knobShadowRadius,
                        y: Theme.Control.knobShadowY
                    )
                    .frame(width: Theme.Control.switchKnob, height: Theme.Control.switchKnob)
                    .padding(Theme.Control.switchInset)
            }
            .frame(width: Theme.Control.switchWidth, height: Theme.Control.switchHeight)
            .modifier(FocusRing(isFocused: isFocused, shape: shape))
    }
}

// MARK: - Select

/// The kit's select: a paper control (radius 8) that opens a real menu below itself. Built
/// on a button that pops up an `NSMenu`, so it joins the Tab loop and opens with Space like
/// the other controls; SwiftUI's `Menu` can't be opened from the keyboard that way.
struct NidusSelect<Value: Hashable>: View {
    let label: String
    let selection: Value
    let options: [Value]
    let title: (Value) -> String
    var icon: String?
    let onSelect: (Value) -> Void

    @State private var anchor = ViewAnchor()

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: Theme.Control.selectSpacing) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: Theme.Control.selectIcon))
                        .foregroundStyle(Theme.Colour.link)
                }
                Text(title(selection))
                Image(systemName: "chevron.down")
                    .font(.system(size: Theme.Control.selectChevron, weight: .bold))
                    .foregroundStyle(Theme.Colour.secondaryText)
            }
        }
        .buttonStyle(NidusButtonStyle(kind: .select))
        .background(AnchorView(anchor: anchor))
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }

    private func popUp() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        for option in options {
            let item = ClosureMenuItem(title: title(option)) { onSelect(option) }
            item.state = option == selection ? .on : .off
            menu.addItem(item)
        }
        let below = view.isFlipped ? view.bounds.maxY + Theme.Control.menuGap : -Theme.Control.menuGap
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
    }
}

/// Holds the AppKit view behind a SwiftUI control, to position a menu on it.
@MainActor
final class ViewAnchor {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used from a nib") }

    @objc private func run() { handler() }
}

// MARK: - Fields

extension View {
    /// The kit's text field: paper, radius 8, a 3:1 boundary, a moss border when focused
    /// (and the ring after keyboard use), red when the last attempt failed.
    func nidusField(isFocused: Bool, isError: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Control.cornerRadius, style: .continuous)
        return textFieldStyle(.plain)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Colour.bodyText)
            .padding(.vertical, Theme.Control.fieldVerticalPadding)
            .padding(.horizontal, Theme.Control.fieldHorizontalPadding)
            .background(Theme.Colour.paper, in: shape)
            .overlay {
                shape.strokeBorder(
                    isError ? Theme.Colour.error : isFocused ? Theme.Colour.accent : Theme.Colour.controlBoundary,
                    lineWidth: Theme.Control.fieldBorder)
            }
            .overlay {
                shape.inset(by: -(Theme.Control.focusRingOffset + Theme.Control.focusRing / 2))
                    .stroke(
                        isError ? Theme.Colour.error : Theme.Colour.focusRing, lineWidth: Theme.Control.focusRing
                    )
                    .opacity(isError || (isFocused && FocusVisibility.shared.isVisible) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(Theme.Motion.hover, value: isFocused)
    }
}

// MARK: - Info cards

/// The kit's info cards: neutral (signer, steps, notices), warn (amber) and error (red).
enum CardKind {
    case ok
    case warn
    case error

    var fill: Color {
        switch self {
        case .ok: Theme.Colour.infoFill
        case .warn: Theme.Colour.warnFill
        case .error: Theme.Colour.errorFill
        }
    }

    var icon: Color {
        switch self {
        case .ok: Theme.Colour.good
        case .warn: Theme.Colour.warning
        case .error: Theme.Colour.error
        }
    }

    var text: Color {
        switch self {
        case .warn: Theme.Colour.warnText
        case .ok, .error: Theme.Colour.bodyText
        }
    }

    var title: Color {
        switch self {
        case .warn: Theme.Colour.warnTitle
        case .ok, .error: Theme.Colour.bodyText
        }
    }
}

// MARK: - Progress capsule

/// The primary capsule as the progress (Progress board): moss fills it left to right over
/// moss at 22%, and the label reads "Installing… 62%" with rolling, monospaced digits. The
/// label is drawn twice and clipped by the fill, body text over the unfilled part and
/// white over the moss, so every glyph keeps its contrast wherever the edge passes.
/// Reduce Motion: the fill and the digits jump to each value.
struct ProgressCapsule: View {
    /// Held under `Theme.Motion.progressCeiling` by the caller until done.
    let fraction: Double
    var size: NidusButtonStyle.Size = .regular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = Capsule()
        let clamped = min(max(fraction, 0), 1)
        let percent = Int((clamped * 100).rounded())
        label(colour: Theme.Colour.bodyText, percent: percent)
            .padding(.horizontal, Theme.Button.padding)
            .frame(minWidth: size == .hero ? Theme.Button.heroWidth : nil, minHeight: height)
            .background { shape.fill(Theme.Colour.accent.opacity(Theme.Motion.progressTrackOpacity)) }
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let width = geometry.size.width * clamped
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.Colour.accent).frame(width: width)
                        label(colour: Theme.Colour.onAccent, percent: percent)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .mask(alignment: .leading) { Rectangle().frame(width: width) }
                    }
                }
            }
            .clipShape(shape)
            .animation(reduceMotion ? nil : Theme.Motion.progress, value: clamped)
            .accessibilityElement()
            .accessibilityLabel("Installing")
            .accessibilityValue("\(percent) percent")
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var height: CGFloat { size == .hero ? Theme.Button.heroHeight : Theme.Button.height }

    private func label(colour: Color, percent: Int) -> some View {
        Text("Installing\u{2026} \(percent)%")
            .font(size == .hero ? Theme.Font.heroPrimaryButton : Theme.Font.primaryButton)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(percent)))
            .animation(reduceMotion ? nil : Theme.Motion.numbers, value: percent)
            .foregroundStyle(colour)
            .singleLineLabel()
    }
}
