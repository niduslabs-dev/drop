import SwiftUI

// Drop's motion, after Purge's techniques (`.claude/research/purge-design.md`), with the
// values in `Theme.Motion`. Each piece reads Reduce Motion and falls back to a plain fade or
// to no animation at all.

/// Blur, fade and drift: the state of a view on its way in or out.
private struct BlurFade: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    let offset: CGSize

    func body(content: Content) -> some View {
        content.blur(radius: blur).opacity(opacity).offset(offset)
    }
}

extension AnyTransition {
    /// Purge's `blurFade`: blurred, transparent and moved by `offsetY` while inactive.
    static func blurFade(radius: CGFloat, offsetY: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurFade(blur: radius, opacity: 0, offset: CGSize(width: 0, height: offsetY)),
            identity: BlurFade(blur: 0, opacity: 1, offset: .zero))
    }

    /// The status line swap: the old line blurs up and away, the new one sharpens in from
    /// below. Reduce Motion: a cross-fade.
    static func statusSwap(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .blurFade(radius: Theme.Motion.swapBlur, offsetY: Theme.Motion.swapOffset),
                removal: .blurFade(radius: Theme.Motion.swapBlur, offsetY: -Theme.Motion.swapOffset))
    }
}

/// Swaps its content with the status blur whenever `key` changes. The old and new content
/// overlap in a `ZStack`, left-aligned, so the line never jumps.
struct StatusSwap<Key: Hashable, Content: View>: View {
    let key: Key
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .id(key)
                .transition(.statusSwap(reduceMotion: reduceMotion))
        }
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.swap, value: key)
    }
}

/// An element of an onboarding page that blurs in after the ones before it (blur 10 to 0,
/// 0.45 s, 0.08 s apart). Reduce Motion: it's simply there.
struct StaggeredBlurIn: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .blur(radius: shown || reduceMotion ? 0 : Theme.Motion.staggerBlur)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeOut(duration: Theme.Motion.staggerDuration).delay(Double(index) * Theme.Motion.staggerStep)
                ) { shown = true }
            }
    }
}

extension View {
    func staggeredBlurIn(_ index: Int) -> some View { modifier(StaggeredBlurIn(index: index)) }
}

/// The popup's content as it slides in: blurred and nudged right, then sharp and in place
/// on the popup spring. The window frame slides separately (`PanelWindowController`).
/// Reduce Motion: no blur or offset (the window fades instead).
struct PopupEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .blur(radius: shown || reduceMotion ? 0 : Theme.Motion.popupBlur)
            .offset(x: shown || reduceMotion ? 0 : Theme.Motion.popupOffset)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Theme.Motion.popup) { shown = true }
            }
    }
}

/// The drawn Installed check: a filled circle that springs from 85% to full size, then a
/// check stroked in over 0.6 s. Reduce Motion: drawn at once.
struct DrawnCheck: View {
    var fill: Color = Theme.Colour.success
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scaled = false
    @State private var drawn = false

    var body: some View {
        Circle().fill(fill)
            .overlay {
                CheckMark()
                    .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                    .stroke(
                        Theme.Colour.onAccent,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
            .scaleEffect(scaled || reduceMotion ? 1 : Theme.Motion.checkScaleFrom)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Theme.Motion.checkScale) { scaled = true }
                withAnimation(Theme.Motion.checkDraw.delay(Theme.Motion.checkBeat)) { drawn = true }
            }
            .accessibilityHidden(true)
    }
}

/// Purge's check points, (0.18, 0.56) → (0.42, 0.78) → (0.84, 0.26) of a square, drawn inside
/// the circle's inner square so it sits optically centred.
private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: rect.width * Self.inset, dy: rect.height * Self.inset)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: inner.minX + x * inner.width, y: inner.minY + y * inner.height)
        }
        var path = Path()
        path.move(to: point(0.18, 0.56))
        path.addLine(to: point(0.42, 0.78))
        path.addLine(to: point(0.84, 0.26))
        return path
    }

    /// How far in from the circle's bounding box the check's square sits.
    private static let inset: CGFloat = 0.2
}
