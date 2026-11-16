import CoreGraphics
import Testing

@testable import DropApp

/// Onboarding's one bottom-anchored rhythm (Onboarding1 to Onboarding5): the same gaps on
/// every page, the dots never move, and only the art panel absorbs the difference.
struct OnboardingRhythmTests {
    typealias Rhythm = Theme.Onboarding.Rhythm

    @Test func windowIsTheApprovedSize() {
        #expect(Theme.Onboarding.width == 600)
        #expect(Theme.Onboarding.height == 540)
    }

    @Test func gapsMatchTheBoards() {
        #expect(Rhythm.dotsBottom == 24)
        #expect(Rhythm.actionsToDots == 20)
        #expect(Rhythm.actionSpacing == 12)
        #expect(Rhythm.textToActions == 24)
        #expect(Rhythm.bodyToInfo == 12)
        #expect(Rhythm.headingToBody == 8)
        #expect(Rhythm.artToHeading == 32)
        #expect(Theme.onboardingInset == 24, "the art panel's side inset")
        #expect(Theme.Button.heroWidth == 240)
        #expect(Theme.Button.heroHeight == 38)
    }

    @Test func dotsSitAtTheSamePlaceOnEveryPage() {
        #expect(Rhythm.dotsTop == 540 - 24 - Theme.Onboarding.dot)
    }

    @Test func fewerElementsGiveATallerArtPanel() {
        let titleBar: CGFloat = 28
        let one = Rhythm.artHeight(titleBar: titleBar, textHeight: 80, actions: 1)
        let two = Rhythm.artHeight(titleBar: titleBar, textHeight: 80, actions: 2)
        #expect(one - two == Theme.Button.heroHeight + Rhythm.actionSpacing)
        let withInfo = Rhythm.artHeight(titleBar: titleBar, textHeight: 100, actions: 2)
        #expect(two - withInfo == 20)
        // Everything adds back up to the window.
        let total = titleBar + one + 32 + 80 + 24 + 38 + 20 + Theme.Onboarding.dot + 24
        #expect(total == Theme.Onboarding.height)
    }
}
