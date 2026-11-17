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
///
/// The ring is in the view tree only while it shows. SwiftUI makes a button's or a select's
/// accessibility frame the union of everything it draws, so a ring kept at opacity 0 would
/// grow the control's frame by the ring's 4 pt on every side: VoiceOver's outline would be a
/// 36 pt select instead of 28.
struct FocusRing<S: InsettableShape>: ViewModifier {
    let isFocused: Bool
    let shape: S
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let shown = isFocused && appearsActive && FocusVisibility.shared.isVisible
        content.overlay {
            if shown {
                shape.inset(by: -(Theme.Control.focusRingOffset + Theme.Control.focusRing / 2))
                    .stroke(Theme.Colour.focusRing, lineWidth: Theme.Control.focusRing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Buttons

/// Primary (moss capsule), secondary (paper capsule with a hairline) and link (text). The
/// select is its own control (`NidusSelect`, Select.swift). A `PrimitiveButtonStyle`, so it
/// can trigger the button from Space and draw its own pressed state; Return still reaches
/// `.keyboardShortcut`.
struct NidusButtonStyle: PrimitiveButtonStyle {
    enum Kind {
        case primary
        case secondary
        case link(Color)
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
        case .plain: RoundedRectangle(cornerRadius: Theme.Control.cornerRadius, style: .continuous)
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
                .overlay { Hairline(shape: shape, width: Theme.Button.hairline) }
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
///
/// With `.labelsHidden()` it draws only the switch, and that is also its accessibility
/// element and frame (34 × 20, as AppKit's switch), which VoiceOver outlines. Settings rows
/// use it that way (`SwitchRow`); with the label drawn (the panel's Trash switch), the
/// element is the whole row.
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
    @Environment(\.labelsVisibility) private var labelsVisibility
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .onTapGesture { toggle() }
            .nidusFocusable($isFocused, enabled: isEnabled) { toggle() }
            .opacity(isEnabled ? 1 : Theme.Control.disabledOpacity)
            .animation(Theme.Motion.enable, value: isEnabled)
            // One element named by the label's text (or the caller's accessibility label when
            // it's hidden), read as a switch with its state, and toggled by VoiceOver's press
            // like the native switch.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "on" : "off")
            .accessibilityAction { toggle() }
    }

    @ViewBuilder private var content: some View {
        if labelsVisibility == .hidden {
            track
        } else {
            HStack(spacing: Theme.Control.switchLabelSpacing) {
                VStack(alignment: .leading, spacing: Theme.Control.captionSpacing) { configuration.label }
                Spacer(minLength: 0)
                track
            }
            .contentShape(Rectangle())
        }
    }

    private func toggle() {
        guard isEnabled else { return }
        withAnimation(reduceMotion ? nil : Theme.Motion.toggle) { configuration.isOn.toggle() }
    }

    private var track: some View {
        let shape = Capsule()
        return shape.fill(configuration.isOn ? Theme.Colour.accent : Theme.Colour.switchOff)
            .overlay {
                // The off track's edge is for Increase Contrast only (the Switch contract).
                shape.strokeBorder(Theme.Colour.controlBoundary, lineWidth: Theme.Control.switchBorder)
                    .opacity(!configuration.isOn && contrast == .increased ? 1 : 0)
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
                // In the tree only while shown, as `FocusRing`, so the field's accessibility
                // frame stays the field's own.
                if isError || (isFocused && FocusVisibility.shared.isVisible) {
                    shape.inset(by: -(Theme.Control.focusRingOffset + Theme.Control.focusRing / 2))
                        .stroke(
                            isError ? Theme.Colour.error : Theme.Colour.focusRing, lineWidth: Theme.Control.focusRing
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(Theme.Motion.hover, value: isFocused)
    }
}

// MARK: - Info cards

/// The kit's info cards: neutral (signer, steps, notices), info (moss: nothing is wrong,
/// here is what happens), warn (amber) and error (red).
enum CardKind: Hashable {
    case ok
    case info
    case warn
    case error

    var fill: Color {
        switch self {
        case .ok: Theme.Colour.infoFill
        case .info: Theme.Colour.mossFill
        case .warn: Theme.Colour.warnFill
        case .error: Theme.Colour.errorFill
        }
    }

    var icon: Color {
        switch self {
        case .ok: Theme.Colour.good
        case .info: Theme.Colour.mossIcon
        case .warn: Theme.Colour.warning
        case .error: Theme.Colour.error
        }
    }

    var text: Color {
        switch self {
        case .warn: Theme.Colour.warnText
        case .ok, .info, .error: Theme.Colour.bodyText
        }
    }

    var title: Color {
        switch self {
        case .warn: Theme.Colour.warnTitle
        case .ok, .info, .error: Theme.Colour.bodyText
        }
    }
}

// MARK: - Progress capsule

/// The primary capsule in every state of the install flow (`PanelButtons.Primary`), as one
/// view, so each change animates in place instead of one button replacing another:
///
/// - solid moss with a label that blur-swaps (Install, Quit and Update, Open …);
/// - the progress (Progress board): moss fills it left to right over moss at 22%, growing
///   in from the left edge, and the label reads "Installing… 62%" with rolling, monospaced
///   digits. The label is drawn twice and clipped by the fill, body text over the unfilled
///   part and white over the moss, so every glyph keeps its contrast wherever the edge is;
/// - waiting for an app to quit: the same track with a slow shimmer and no number.
///
/// The solid button and the track are two layers of one capsule that cross-fade; the
/// capsule is as wide as its label (240 in the install window) and its width animates.
/// Reduce Motion: plain fades, no shimmer, and the fill and digits jump to each value.
struct StepCapsule: View {
    let step: PanelButtons.Primary
    var size: NidusButtonStyle.Size = .regular
    let send: (PanelAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // An invisible label sets the size; both layers fill it.
        Text(step.sizingLabel)
            .font(font)
            .monospacedDigit()
            .singleLineLabel()
            .hidden()
            .accessibilityHidden(true)
            .padding(.horizontal, Theme.Button.padding)
            .frame(minWidth: size == .hero ? Theme.Button.heroWidth : nil, minHeight: height)
            .overlay { track.opacity(step.isSolid ? 0 : 1) }
            .overlay { solid.opacity(step.isSolid ? 1 : 0) }
            .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.popup, value: step.isSolid)
            .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.popup, value: step.sizingLabel)
    }

    private var height: CGFloat { size == .hero ? Theme.Button.heroHeight : Theme.Button.height }
    private var font: Font { size == .hero ? Theme.Font.heroPrimaryButton : Theme.Font.primaryButton }

    /// The real button: hover, press, focus ring and Return, whenever there's an action.
    private var solid: some View {
        Button {
            if let action = step.action { send(action) }
        } label: {
            StatusSwap(key: solidTitle) { Text(solidTitle).frame(maxWidth: .infinity) }
        }
        .buttonStyle(NidusButtonStyle(kind: .primary, size: size))
        .keyboardShortcut(.defaultAction)
        .allowsHitTesting(step.action != nil)
        .accessibilityHidden(!step.isSolid)
    }

    /// The solid layer keeps its last label while the track covers it, so nothing swaps
    /// unseen and then pops.
    private var solidTitle: String { step.isSolid ? step.label : "" }

    private var track: some View {
        let shape = Capsule()
        return GeometryReader { geometry in
            let width = geometry.size.width * step.fill
            ZStack(alignment: .leading) {
                shape.fill(Theme.Colour.accent.opacity(Theme.Motion.progressTrackOpacity))
                if case .quitting = step, !reduceMotion {
                    Shimmer().transition(.opacity)
                }
                trackLabel(colour: Theme.Colour.bodyText)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                Rectangle().fill(Theme.Colour.accent).frame(width: width)
                trackLabel(colour: Theme.Colour.onAccent)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: width) }
            }
        }
        .clipShape(shape)
        .animation(reduceMotion ? nil : Theme.Motion.progress, value: step.fill)
        .accessibilityElement()
        .accessibilityLabel(step.isSolid ? "" : step.phrase)
        .accessibilityValue(progressValue)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityHidden(step.isSolid)
    }

    private var progressValue: String {
        if case .progress(_, let fraction) = step { return "\(PanelButtons.Primary.percent(fraction)) percent" }
        return ""
    }

    private func trackLabel(colour: Color) -> some View {
        let percent = PanelButtons.Primary.percent(step.fill)
        return StatusSwap(key: step.isSolid ? "" : step.phrase) {
            Text(step.isSolid ? "" : step.label)
                .font(font)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(percent)))
                .animation(reduceMotion ? nil : Theme.Motion.numbers, value: percent)
                .foregroundStyle(colour)
                .singleLineLabel()
                .frame(maxWidth: .infinity)
        }
    }
}

/// The waiting capsule's shimmer: a soft band of moss that crosses the track again and
/// again. Only drawn when motion isn't reduced.
private struct Shimmer: View {
    @State private var crossed = false

    var body: some View {
        GeometryReader { geometry in
            let band = geometry.size.width * Theme.Motion.shimmerBand
            LinearGradient(
                colors: [.clear, Theme.Colour.accent.opacity(Theme.Motion.shimmerOpacity), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: band)
            .offset(x: crossed ? geometry.size.width : -band)
            .onAppear {
                withAnimation(.linear(duration: Theme.Motion.shimmerDuration).repeatForever(autoreverses: false)) {
                    crossed = true
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A button label that blur-swaps when its text changes, in a button that stays the same
/// view (Not now, Cancel, Show in Finder). `fills` centres it in a fixed-width capsule.
struct SwapLabel: View {
    let title: String
    var fills = false

    var body: some View {
        StatusSwap(key: title) { Text(title).frame(maxWidth: fills ? .infinity : nil) }
    }
}

/// Dims a label with the control it names. The kit's controls dim themselves when
/// disabled (`Theme.Control.disabledOpacity`, on `Theme.Motion.enable`); a plain `Text`
/// beside one doesn't, so a row would dim only by half. This gives the label the same
/// opacity on the same animation, so the row dims and comes back as one.
///
/// Put it on the label alone, never on a container that holds a kit control: the control
/// would dim twice.
private struct DimsWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : Theme.Control.disabledOpacity)
            .animation(Theme.Motion.enable, value: isEnabled)
    }
}

extension View {
    /// The label of a row whose control is a kit control (see `DimsWhenDisabled`).
    func dimsWhenDisabled() -> some View { modifier(DimsWhenDisabled()) }
}
