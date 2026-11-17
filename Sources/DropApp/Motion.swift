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

/// Text whose numbers roll as they change, in place of SwiftUI's `.numericText()` and
/// matched to it: each changed character leaves and its replacement arrives on its own,
/// left to right a beat apart, rising (falling, when `value` drops) with a slight scale
/// and a light blur that clears before the move settles. Characters that didn't change
/// stay put, sliding only when the text around them grows or shrinks. Reduce Motion: the
/// changed characters cross-fade.
///
/// Why not `.numericText()`: it blurs inside text drawing, where CoreGraphics caches a
/// glyph bitmap for every blurred frame, about 5.5 MB per DMG offered and never freed.
/// Here every motion is a view-level modifier on plain `Text`, which caches nothing per
/// frame (`.claude/research/drop-memory.md`, probe C2 and the custom roll).
///
/// At rest it is one `Text`, so still frames are exactly a `Text`'s. A change is measured
/// first: for one frame, `GlyphProbe`s lay out the old and new text without drawing them,
/// giving each character's x in the real layout (adding up per-character widths drifts,
/// since each `Text` rounds its own width to the pixel grid). The roll then draws one
/// `Text` per character at those positions, over a hidden `Text` of the new text that
/// sets the size, and merges back into one `Text` once the last character settles. Font
/// and colour come from the environment, as for `Text`.
struct RollingNumber: View {
    let text: String
    /// The number the text shows, when it has one: the roll goes down when it falls, as
    /// with `.numericText(value:)`. Otherwise it always rolls up.
    let value: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The text at rest, or the text the roll on screen is heading to.
    @State private var settled: String
    /// A change waiting for its layout.
    @State private var pending: String?
    @State private var layouts: [String: [GlyphProbe.Cluster]] = [:]
    /// The characters on screen while rolling; nil at rest.
    @State private var glyphs: [Glyph]?
    @State private var lastValue: Double?
    @State private var nextID = 0
    /// Bumped by each change, so work queued for an older one does nothing.
    @State private var generation = 0

    init(_ text: String, value: Double? = nil) {
        self.text = text
        self.value = value
        _settled = State(initialValue: text)
        _lastValue = State(initialValue: value)
    }

    var body: some View {
        Text(settled)
            .opacity(glyphs == nil ? 1 : 0)
            .overlay(alignment: .topLeading) {
                if let glyphs {
                    ZStack(alignment: .topLeading) {
                        ForEach(glyphs) { RollingGlyph(glyph: $0, reduceMotion: reduceMotion) }
                    }
                    .accessibilityHidden(true)
                }
            }
            .background(alignment: .topLeading) {
                if let pending {
                    ZStack(alignment: .topLeading) {
                        if glyphs == nil { probe(settled) }
                        probe(pending)
                    }
                    .accessibilityHidden(true)
                }
            }
            .monospacedDigit()
            .accessibilityRepresentation { Text(text) }
            .onChange(of: text) { _, new in change(to: new) }
    }

    private func probe(_ string: String) -> some View {
        Text(string).fixedSize()
            .textRenderer(GlyphProbe(text: string) { @MainActor clusters in measured(string, clusters) })
    }

    /// Queues `new` for measuring. Should its layout never arrive (nothing drawn, say in a
    /// hidden window), it shows unrolled after `rollMeasureLimit`.
    private func change(to new: String) {
        generation += 1
        let mine = generation
        withTransaction(Self.still) { pending = new }
        Task { @MainActor in
            try? await Task.sleep(for: Theme.Motion.rollMeasureLimit)
            guard mine == generation, pending != nil else { return }
            merge(into: new)
        }
    }

    /// Once the old and new layouts are both in, places the glyphs where they start (the
    /// old characters exactly where the single `Text` drew them, the new ones waiting out
    /// of sight), then moves them all on the next update: a view has to be drawn in its
    /// starting state before a change of state can animate it.
    private func measured(_ string: String, _ clusters: [GlyphProbe.Cluster]?) {
        guard let new = pending, string == new || (glyphs == nil && string == settled),
            layouts[string] == nil
        else { return }
        guard let clusters else { return merge(into: new) }
        layouts[string] = clusters
        guard let target = layouts[new] else { return }
        let from: [Glyph]
        if let glyphs {
            from = glyphs.filter { $0.phase != .leaving }
        } else {
            guard let start = layouts[settled] else { return }
            from = start.map { Glyph(id: newID(), text: $0.text, x: $0.x) }
        }
        let falling = value.flatMap { now in lastValue.map { now < $0 } } ?? false
        lastValue = value
        let staged = stage(from: from, to: target, falling: falling)
        withTransaction(Self.still) {
            pending = nil
            glyphs = staged
        }
        let mine = generation
        Task { @MainActor in
            guard mine == generation else { return }
            roll(to: new)
        }
    }

    /// The glyphs at the start of a roll: leaving ones still on their way out, the old
    /// characters (each kept or marked to leave), and the new ones waiting to arrive.
    private func stage(from: [Glyph], to target: [GlyphProbe.Cluster], falling: Bool) -> [Glyph] {
        let diff = RollDiff(from: from.map(\.text), to: target.map(\.text))
        let rise = (falling ? -1 : 1) * Theme.Motion.rollRise
        let stagger = reduceMotion ? 0 : Theme.Motion.rollStagger(slots: diff.slots)
        let now = ContinuousClock.now
        var staged = glyphs?.filter { $0.phase == .leaving && !$0.isGone(at: now) } ?? []
        var keptOld = Set<Int>()
        var arriving: [Glyph] = []
        for (index, cluster) in target.enumerated() {
            if let old = diff.kept[index], !(reduceMotion && from[old].x != cluster.x) {
                keptOld.insert(old)
                var glyph = from[old]
                glyph.targetX = cluster.x
                staged.append(glyph)
            } else {
                let delay = Double(diff.entering[index] ?? 0) * stagger
                arriving.append(
                    Glyph(id: newID(), text: cluster.text, x: cluster.x, phase: .arriving, rise: rise, delay: delay))
            }
        }
        for (index, glyph) in from.enumerated() where !keptOld.contains(index) {
            var leaving = glyph
            leaving.phase = .toLeave
            leaving.rise = rise
            leaving.delay = Double(diff.leaving[index] ?? 0) * stagger
            staged.append(leaving)
        }
        return staged + arriving
    }

    private func roll(to new: String) {
        guard let staged = glyphs else { return }
        withAnimation(reduceMotion ? Theme.Motion.fade : Theme.Motion.numbers) {
            settled = new
            glyphs = staged.map { glyph in
                var moved = glyph
                moved.x = glyph.targetX
                switch glyph.phase {
                case .arriving: moved.phase = .shown
                case .toLeave:
                    moved.phase = .leaving
                    moved.leftAt = .now
                case .shown, .leaving: break
                }
                return moved
            }
        }
        let last = staged.map(\.delay).max() ?? 0
        let settle = reduceMotion ? Theme.Motion.fadeDuration : Theme.Motion.rollSettle
        let mine = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(last + settle))
            guard mine == generation else { return }
            merge(into: new)
        }
    }

    /// Back to one `Text`, with nothing animating.
    private func merge(into new: String) {
        withTransaction(Self.still) {
            settled = new
            pending = nil
            glyphs = nil
            layouts = [:]
        }
    }

    private func newID() -> Int {
        nextID += 1
        return nextID
    }

    private static var still: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }
}

/// One character of a rolling number, at its x in the laid-out text.
private struct Glyph: Identifiable {
    enum Phase {
        /// Waiting below (above, when falling) to come in.
        case arriving
        case shown
        /// Shown, and leaves when the roll starts.
        case toLeave
        case leaving
    }

    let id: Int
    let text: String
    var x: CGFloat
    /// Where the roll takes it.
    var targetX: CGFloat
    var phase: Phase
    /// Signed: positive arrives from below and leaves upward.
    var rise: CGFloat
    /// Its place in the left-to-right stagger.
    var delay: Double
    /// When it started leaving.
    var leftAt: ContinuousClock.Instant?

    /// Done leaving, so a later roll can drop it: changes can come faster than a roll
    /// settles, and leaving glyphs would otherwise pile up until the last one merges.
    func isGone(at now: ContinuousClock.Instant) -> Bool {
        guard let leftAt else { return false }
        return now - leftAt > .seconds(delay + Theme.Motion.rollSettle)
    }

    init(id: Int, text: String, x: CGFloat, phase: Phase = .shown, rise: CGFloat = 0, delay: Double = 0) {
        self.id = id
        self.text = text
        self.x = x
        self.targetX = x
        self.phase = phase
        self.rise = rise
        self.delay = delay
    }
}

/// Draws a `Glyph`: the move and scale on `rollSpring`, the fade evenly over
/// `rollFadeDuration` and the blur over the shorter `rollBlurDuration`, each after the
/// glyph's delay. Reduce Motion: only the fade.
private struct RollingGlyph: View {
    let glyph: Glyph
    let reduceMotion: Bool

    var body: some View {
        let away = glyph.phase == .arriving || glyph.phase == .leaving
        let offset: CGFloat =
            reduceMotion ? 0 : glyph.phase == .arriving ? glyph.rise : glyph.phase == .leaving ? -glyph.rise : 0
        Text(glyph.text).fixedSize()
            .blur(radius: away && !reduceMotion ? Theme.Motion.rollBlur : 0)
            .animation(.easeOut(duration: Theme.Motion.rollBlurDuration).delay(glyph.delay), value: glyph.phase)
            .opacity(away ? 0 : 1)
            .animation(fade, value: glyph.phase)
            .modifier(GlyphMove(gone: away && !reduceMotion, offset: offset))
            .animation(move, value: glyph.phase)
            .offset(x: glyph.x)
    }

    private var fade: Animation {
        (reduceMotion ? Theme.Motion.fade : .linear(duration: Theme.Motion.rollFadeDuration)).delay(glyph.delay)
    }
    private var move: Animation { .spring(Theme.Motion.rollSpring).delay(glyph.delay) }
}

/// A rolling glyph's place and size: gone is moved by `offset` and scaled to `rollScale`.
private struct GlyphMove: ViewModifier {
    let gone: Bool
    let offset: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(gone ? Theme.Motion.rollScale : 1)
            .offset(y: offset)
    }
}

/// Which characters of a rolling number stay and which roll. The unchanged start and end
/// stay; in between, characters pair up from the right, as digits do when a number gains
/// a place, and a pair that differs is one slot of the stagger: its old character leaves
/// as its new one arrives. Whitespace takes no slot of its own.
struct RollDiff: Equatable {
    /// New index → the old index of the same character, which stays.
    var kept: [Int: Int] = [:]
    /// Old index → its stagger slot.
    var leaving: [Int: Int] = [:]
    /// New index → its stagger slot.
    var entering: [Int: Int] = [:]
    var slots = 0

    init(from old: [String], to new: [String]) {
        let shorter = min(old.count, new.count)
        var head = 0
        while head < shorter, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < shorter - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        for index in 0..<head { kept[index] = index }
        for offset in 0..<tail { kept[new.count - 1 - offset] = old.count - 1 - offset }
        let oldEnd = old.count - tail
        let newEnd = new.count - tail
        let span = max(oldEnd - head, newEnd - head)
        for fromRight in (0..<span).reversed() {
            let o = oldEnd - 1 - fromRight
            let n = newEnd - 1 - fromRight
            let hasOld = o >= head
            let hasNew = n >= head
            if hasOld, hasNew, old[o] == new[n] {
                kept[n] = o
                continue
            }
            if hasOld { leaving[o] = slots }
            if hasNew { entering[n] = slots }
            let shown = (hasOld ? old[o] : "") + (hasNew ? new[n] : "")
            if !shown.allSatisfy(\.isWhitespace) { slots += 1 }
        }
    }
}

/// Reads where each character of a `Text` lands in its layout, and draws nothing. The
/// x comes from the glyph that draws the character; characters that share a glyph (a
/// ligature) become one cluster. Reports nil when the layout can't be mapped back to the
/// string, and the change then shows unrolled.
struct GlyphProbe: TextRenderer {
    struct Cluster: Equatable, Sendable {
        var text: String
        var x: CGFloat
    }

    let text: String
    let report: @MainActor @Sendable ([Cluster]?) -> Void

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let clusters = Self.clusters(of: text, in: layout)
        let report = report
        Task { @MainActor in report(clusters) }
    }

    static func clusters(of text: String, in layout: Text.Layout) -> [Cluster]? {
        var glyphs: [(index: Text.Layout.CharacterIndex, glyph: Int, x: CGFloat)] = []
        var glyph = 0
        for line in layout {
            for run in line {
                for slice in run {
                    for index in slice.characterIndices {
                        glyphs.append((index, glyph, slice.typographicBounds.origin.x))
                    }
                    glyph += 1
                }
            }
        }
        guard let first = glyphs.map(\.index).min() else { return text.isEmpty ? [] : nil }
        var byOffset: [Int: (glyph: Int, x: CGFloat)] = [:]
        for entry in glyphs {
            let offset = first.distance(to: entry.index)
            if let seen = byOffset[offset], seen.x <= entry.x { continue }
            byOffset[offset] = (entry.glyph, entry.x)
        }
        var clusters: [Cluster] = []
        var lastGlyph: Int?
        var offset = 0
        for character in text {
            guard let found = byOffset[offset] else { return nil }
            if found.glyph == lastGlyph, !clusters.isEmpty {
                clusters[clusters.count - 1].text.append(character)
            } else {
                clusters.append(Cluster(text: String(character), x: found.x))
            }
            lastGlyph = found.glyph
            offset += character.utf16.count
        }
        return clusters
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
