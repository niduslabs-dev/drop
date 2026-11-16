/// Where first-run onboarding plugs in (being designed). Until it exists, onboarding is
/// always done. Anything that needs the user's understanding first waits on `isComplete`:
///
/// - Watching the folder. Drop's first access to `~/Downloads` (and so macOS's
///   "Drop would like to access files in your Downloads folder" prompt) happens when
///   the watcher starts and checks the first file there. Onboarding should explain it before
///   calling `finish()`.
/// - "Open disk images with Drop". Drop never asks to become the default by itself; only
///   the Settings switch, or onboarding when the user agrees, calls `DiskImageHandler`.
@MainActor
final class OnboardingCoordinator {
    var isComplete: Bool { true }

    /// Called by onboarding when the user is through it; starts what was waiting.
    var onFinish: () -> Void = {}

    func finish() { onFinish() }
}
