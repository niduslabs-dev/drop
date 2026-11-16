import Foundation
import Installer
import os

/// The panel's first-time milestones for one DMG, as info logs and signpost events with the
/// milliseconds since the popup was shown: popup, summary (name and version), icon, size and
/// verified. `.claude/research/summary-latency.md` reads them with
/// `log show --predicate 'category == "latency"'`.
@MainActor
final class LatencyMarks {
    enum Milestone: String, CaseIterable {
        case summary, icon, size, verified
    }

    private static let log = Logger(subsystem: "dev.niduslabs.drop", category: "latency")
    private static let signposter = OSSignposter(logger: log)

    private let shownAt = ContinuousClock.now
    private let image: String
    private var seen: Set<Milestone> = []

    /// Call as the popup is shown.
    init(dmg: URL) {
        image = dmg.lastPathComponent
        Self.signposter.emitEvent("popup shown")
        Self.log.notice("popup shown 0 ms \(self.image, privacy: .public)")
    }

    /// Logs each milestone the model has reached for the first time.
    func observe(_ model: PanelModel) {
        if model.summary != nil { mark(.summary) }
        if model.appIcon != nil { mark(.icon) }
        if model.summary?.size != nil { mark(.size) }
        switch model.state {
        case .ready, .warning, .refused: mark(.verified)
        default: break
        }
    }

    private func mark(_ milestone: Milestone) {
        guard seen.insert(milestone).inserted else { return }
        let elapsed = ContinuousClock.now - shownAt
        let ms = Int((elapsed.seconds * 1000).rounded())
        Self.signposter.emitEvent("milestone", "\(milestone.rawValue, privacy: .public)")
        Self.log.notice("\(milestone.rawValue, privacy: .public) shown \(ms) ms \(self.image, privacy: .public)")
    }
}
