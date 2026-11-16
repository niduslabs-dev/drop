import DMGReader
import DiskImage
import Dispatch
import Extractor
import Foundation
import Synchronization
import Verifier

/// How a session stages and installs.
public struct InstallOptions: Sendable {
    /// Where the app goes, usually `/Applications`. Staging happens on its volume, so
    /// installing is a rename.
    public var destination: URL
    /// `.background` while the popup shows ("ready before you click"); `.userInitiated`
    /// when the user already asked to install (the Low Power Mode path, a manual open).
    public var stagingPriority: StageOptions.Priority
    /// The image's decode policy while staging runs at `.background`. Install boosts it to
    /// `.fast`. Injectable so the impact benchmark can compare presets.
    public var backgroundDecodePolicy: DecodePolicy
    /// The "Skip the 'downloaded from the Internet' prompt" setting. When on, a notarized
    /// app that passes the check gets its quarantine written pre-approved.
    public var skipFirstLaunchPrompt: Bool
    /// Moves the replaced copy on an update to the Trash. The app passes
    /// `FileManager.trashItem`; tests pass a folder of their own.
    public var trash: @Sendable (URL) throws -> Void
    /// Told when the image needs the hidden mount. For now it only reports; the session
    /// then ends in `needsMountFallback`.
    public var mountFallback: (@Sendable (_ dmg: URL, _ reason: ReaderError) -> Void)?

    public init(
        destination: URL, stagingPriority: StageOptions.Priority = .background,
        backgroundDecodePolicy: DecodePolicy = .background, skipFirstLaunchPrompt: Bool = false,
        trash: @escaping @Sendable (URL) throws -> Void,
        mountFallback: (@Sendable (_ dmg: URL, _ reason: ReaderError) -> Void)? = nil
    ) {
        self.destination = destination
        self.stagingPriority = stagingPriority
        self.backgroundDecodePolicy = backgroundDecodePolicy
        self.skipFirstLaunchPrompt = skipFirstLaunchPrompt
        self.trash = trash
        self.mountFallback = mountFallback
    }
}

/// One DMG on its way into the destination: reads it, asks for the licence when there is
/// one, stages and checks the app in the background, then installs it on `install()`.
///
/// **Threading.** An actor: every state change and command is serialised on it, and any
/// thread may call it. Nothing blocking runs on the actor or the cooperative pool: opening
/// the image, staging and the rename run on threads of their own (`Extractor.stage` and
/// the reader block), and the signature check uses the Verifier's `async` overloads.
/// The panel reads `state` or iterates `updates` (one consumer; every state, in order,
/// with progress coalesced to `progressSteps` updates per stage) and hops to the main
/// actor itself.
///
/// **Lifetime.** `start()` once. A `ready` or `warning` session keeps its staged copy
/// until `install()` or `cancel()`; call `cancel()` (or `notNow()`) whenever the panel
/// closes without installing, or the staged copy stays until the next launch's sweep.
public actor InstallSession {
    public nonisolated let dmg: URL
    public nonisolated let options: InstallOptions
    /// Every state the session enters, in order. Finishes after the final state.
    public nonisolated let updates: AsyncStream<InstallState>

    /// Progress updates per stage at most: one per percent.
    public static let progressSteps = 100

    public private(set) var state: InstallState = .reading {
        didSet {
            continuation.yield(state)
            if state.isFinal { continuation.finish() }
        }
    }
    public private(set) var timings = InstallTimings()

    private let continuation: AsyncStream<InstallState>.Continuation
    private let job = StagingJob()
    private let stopFlag = Flag()
    private let clock = ContinuousClock()
    private var startedAt: ContinuousClock.Instant?
    private var runTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var licenceAnswer: CheckedContinuation<Bool, Never>?
    /// Set once the user clicked Install; `run` installs as soon as the verdict allows.
    private var installRequested = false
    private var summary: AppSummary?
    private var staged: StagedApp?
    /// For tests: the area being written, and the image's device.
    private(set) var stagingArea: StagingArea?
    private var device: UDIFDevice?

    public init(dmg: URL, options: InstallOptions) {
        self.dmg = dmg
        self.options = options
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts reading the image. Later calls do nothing.
    public func start() {
        guard runTask == nil else { return }
        startedAt = clock.now
        continuation.yield(state)
        runTask = Task { await self.run() }
    }

    /// Accepts the licence shown in `needsLicence`; staging starts.
    public func acceptLicence() { answerLicence(true) }

    /// Declines the licence: the session ends `cancelled` with nothing written.
    public func decline() { answerLicence(false) }

    /// Installs. While preparing, this boosts staging to full speed and installs once the
    /// app is staged and checked (unless the check ends in a warning or refusal: see
    /// `InstallState`). In `warning` it is Install Anyway. Elsewhere it does nothing.
    /// Returns once the session settles: installed, failed, or waiting in `warning`.
    public func install() async {
        switch state {
        case .preparing(let summary, let progress):
            installRequested = true
            timings.boosted = elapsed()
            job.boost()
            state = .installing(summary, progress)
            await runTask?.value
        case .ready, .warning:
            guard installTask == nil else { break }
            let task = Task { await self.moveIntoPlace() }
            installTask = task
            await task.value
        default:
            break
        }
        await installTask?.value
    }

    /// Stops whatever is running and deletes the staged copy, then ends `cancelled`.
    /// Returns once the staged copy is gone from disk. Does nothing once installed.
    public func cancel() async {
        guard !state.isFinal else { return }
        stopFlag.set()
        answerLicence(false)
        runTask?.cancel()
        await runTask?.value
        await installTask?.value
        if let staged {
            self.staged = nil
            await Self.discard(staged.area)
        }
        if !state.isFinal { state = .cancelled }
    }

    /// The popup's Not now: the same as `cancel()`.
    public func notNow() async { await cancel() }

    /// The image device's decode policy right now; nil for raw images or before staging.
    var decodePolicy: DecodePolicy? { device?.decodePolicy }

    // MARK: - The pipeline

    private func run() async {
        let opened: OpenedImage
        let app: Entry
        do {
            let path = dmg.path
            opened = try await Self.onThread(qos: .utility) { try DMGReader.open(path: path) }
            timings.opened = elapsed()
            if let licence = opened.image.licence {
                state = .needsLicence(licence)
                guard await waitForLicence() else { return finishCancelled() }
            }
            guard !stopFlag.isSet else { return finishCancelled() }
            guard let chosen = try chooseApp(in: opened) else { return }
            app = chosen
        } catch {
            return finish(with: error)
        }

        let fileSystem = opened.fileSystem
        let destination = options.destination
        let dmgURL = dmg
        let prepared: Prepared
        do {
            prepared = try await Self.onThread(qos: .utility) {
                try Prepared.make(app: app, fileSystem: fileSystem, destination: destination, dmg: dmgURL)
            }
        } catch {
            return finish(with: error)
        }
        var summary = prepared.summary
        self.summary = summary
        stagingArea = prepared.area
        guard !stopFlag.isSet else {
            Extractor.discard(prepared.area)
            return finishCancelled()
        }
        let initialProgress = InstallProgress(bytesDone: 0, bytesTotal: summary.size)
        state =
            installRequested ? .installing(summary, initialProgress) : .preparing(summary, initialProgress)

        let staged: StagedApp
        do {
            staged = try await stage(app, from: opened, into: prepared.area, quarantine: prepared.quarantine)
        } catch {
            return finish(with: error)
        }
        self.staged = staged
        timings.staged = elapsed()
        guard !stopFlag.isSet else { return finishCancelled() }

        // Staple before the check, so Gatekeeper's answer (and an offline first launch)
        // sees the ticket. Best effort: a failure only means macOS fetches it online.
        if let ticket = prepared.ticket {
            let url = staged.url
            _ = try? await Self.onThread(qos: .utility) { try Verifier.staple(ticket, into: url) }
        }

        let fast = installRequested || options.stagingPriority == .userInitiated
        let verdict = await Verifier.verdict(app: staged.url, qos: fast ? .userInitiated : .utility)
        timings.verified = elapsed()
        guard !stopFlag.isSet, !Task.isCancelled else { return finishCancelled() }

        summary.signer = verdict.signing?.organisation ?? verdict.signing?.signer
        summary.teamID = verdict.signing?.teamID
        summary.isNotarized = verdict.assessment?.assessment?.isCheckedByApple == true
        summary.iconFile = prepared.bundleInfo?.iconURL(inStagedApp: staged.url)
        if let installed = prepared.installedSigning, let signing = verdict.signing {
            summary.update?.developer = Verifier.sameDeveloper(new: signing, installed: installed)
        } else if summary.update != nil {
            // The installed copy's signature couldn't be read: nothing to compare against.
            summary.update?.developer = .installedUnsigned
        }
        self.summary = summary

        if options.skipFirstLaunchPrompt, verdict.allowsPreApproval {
            // On failure the app keeps plain quarantine: macOS shows its usual prompt.
            _ = try? await Self.onThread(qos: .utility) { try Extractor.markApproved(staged) }
        }

        switch verdict.decision {
        case .install:
            // Install already clicked: stay in `installing` rather than flash `ready`.
            if installRequested { await moveIntoPlace() } else { state = .ready(summary) }
        case .warn(let warning):
            installRequested = false
            state = .warning(summary, warning)
        case .refuse(let refusal):
            self.staged = nil
            Extractor.discard(staged)
            state = .refused(summary, refusal)
        }
    }

    /// The single top-level app, or nil after setting `cannotInstall`.
    private func chooseApp(in opened: OpenedImage) throws -> Entry? {
        let apps = try opened.apps()
        if apps.count == 1, let app = apps.first { return app }
        if apps.count > 1 {
            state = .cannotInstall(.multipleApps(names: apps.map(\.name).sorted()))
            return nil
        }
        let packages = try opened.packages()
        state = .cannotInstall(packages.isEmpty ? .noApp : .packageOnly(names: packages.map(\.name).sorted()))
        return nil
    }

    private func stage(
        _ app: Entry, from opened: OpenedImage, into area: StagingArea, quarantine: String?
    ) async throws -> StagedApp {
        let device = opened.image.udif
        self.device = device
        let background = options.stagingPriority == .background && !job.isBoosted
        device?.decodePolicy = background ? options.backgroundDecodePolicy : .fast
        timings.stagingStarted = elapsed()

        let stop = stopFlag
        let throttle = ProgressThrottle(steps: Self.progressSteps)
        let stageOptions = StageOptions(
            quarantine: quarantine, priority: options.stagingPriority, isCancelled: { stop.isSet }, job: job,
            onBoost: { device?.decodePolicy = .fast })
        let fileSystem = opened.fileSystem
        return try await Self.onThread(qos: background ? .background : .userInitiated) {
            try Extractor.stage(app: app, from: fileSystem, into: area, options: stageOptions) { progress in
                guard throttle.shouldEmit(progress) else { return }
                Task { await self.progressed(progress) }
            }
        }
    }

    private func progressed(_ progress: StageProgress) {
        let next = InstallProgress(bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal)
        switch state {
        case .preparing(let summary, let current) where next.bytesDone > current.bytesDone:
            state = .preparing(summary, next)
        case .installing(let summary, let current) where next.bytesDone > current.bytesDone:
            state = .installing(summary, next)
        default:
            break
        }
    }

    /// Renames the staged app into the destination; an existing copy is swapped out and
    /// handed to `options.trash`.
    private func moveIntoPlace() async {
        guard let staged, let summary, !stopFlag.isSet else { return }
        state = .installing(summary, InstallProgress(bytesDone: summary.size, bytesTotal: summary.size))
        let destination = options.destination
        let trash = options.trash
        do {
            let url = try await Self.onThread(qos: .userInitiated) {
                try Extractor.install(staged, into: destination, trash: trash)
            }
            self.staged = nil
            state = .installed(url)
        } catch ExtractorError.trashFailed(let oldCopy, let reason) {
            // The new app is in place; the old copy is still in the staging area. Keep it
            // (it is the user's previous app) and report, rather than deleting it.
            self.staged = nil
            state = .failed(.extractor(.trashFailed(oldCopy: oldCopy, reason: reason)))
        } catch {
            state = .failed(InstallFailure(error))
        }
    }

    private func finish(with error: any Error) {
        switch error {
        case ExtractorError.cancelled:
            finishCancelled()
        case ExtractorError.nameCollision(let paths, _):
            state = .cannotInstall(.nameCollision(paths: paths))
        case let error as ReaderError where error.wantsMountFallback:
            options.mountFallback?(dmg, error)
            state = .needsMountFallback(error)
        case let error as ReaderError:
            state = .cannotInstall(.unreadable(String(describing: error)))
        default:
            state = .failed(InstallFailure(error))
        }
    }

    private func finishCancelled() {
        if !state.isFinal { state = .cancelled }
    }

    private func waitForLicence() async -> Bool {
        guard !stopFlag.isSet else { return false }
        return await withCheckedContinuation { licenceAnswer = $0 }
    }

    private func answerLicence(_ accepted: Bool) {
        guard let answer = licenceAnswer else { return }
        licenceAnswer = nil
        answer.resume(returning: accepted)
    }

    private func elapsed() -> Double? {
        guard let startedAt else { return nil }
        let duration = clock.now - startedAt
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Helpers

    /// Runs blocking work on a thread of its own, so it never parks a cooperative thread.
    /// The thread's QoS is fixed for its life (see `WorkerPriority` in the Extractor), which
    /// is fine for the short calling-thread work `stage` does itself.
    static func onThread<T: Sendable>(
        qos: QualityOfService, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try body() }) }
            thread.qualityOfService = qos
            thread.start()
        }
    }

    static func discard(_ area: StagingArea) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Extractor.discard(area) { continuation.resume() }
        }
    }
}

/// Everything read before staging starts, in one blocking pass off the actor.
private struct Prepared: Sendable {
    var summary: AppSummary
    var bundleInfo: BundleInfo?
    var installedSigning: SigningInfo?
    var ticket: NotarizationTicket?
    var quarantine: String?
    var area: StagingArea

    static func make(app: Entry, fileSystem: any FileSystem, destination: URL, dmg: URL) throws -> Prepared {
        let info = BundleInfo.read(app: app, in: fileSystem)
        var size: UInt64 = 0
        try DMGReader.walk(fileSystem, from: app) { _, entry in
            if entry.kind == .file { size &+= entry.size }
        }
        let fallbackName = app.name.hasSuffix(".app") ? String(app.name.dropLast(".app".count)) : app.name
        var summary = AppSummary(
            bundleName: app.name, name: info?.displayName ?? fallbackName, version: info?.shortVersion,
            bundleIdentifier: info?.identifier, size: size, iconFile: nil, signer: nil, teamID: nil,
            isNotarized: false, update: nil)

        var installedSigning: SigningInfo?
        let installed = destination.appending(path: app.name, directoryHint: .isDirectory)
        var status = stat()
        if lstat(installed.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
            summary.update = AppSummary.Update(
                installedVersion: BundleInfo.read(installedApp: installed)?.shortVersion, developer: nil)
            installedSigning = try? Verifier.signingInfo(app: installed)
        }

        // A DMG without a ticket, or one this code can't parse, just means nothing to staple.
        let ticket = try? Verifier.ticket(fromDMG: dmg.path)
        let quarantine = try Quarantine.read(at: dmg)
        let area = try Extractor.makeStagingArea(for: destination)
        return Prepared(
            summary: summary, bundleInfo: info, installedSigning: installedSigning, ticket: ticket,
            quarantine: quarantine, area: area)
    }
}

/// A one-way flag read from worker threads (`StageOptions.isCancelled`).
final class Flag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    func set() { value.store(true, ordering: .releasing) }
}

/// Lets through one progress report per step (1/steps of the total), from any thread.
final class ProgressThrottle: Sendable {
    private let steps: UInt64
    private let lastStep = Atomic<Int>(-1)

    init(steps: Int) { self.steps = UInt64(max(1, steps)) }

    func shouldEmit(_ progress: StageProgress) -> Bool {
        let step =
            progress.bytesTotal == 0
            ? Int(steps)
            : Int(
                min(
                    steps,
                    progress.bytesDone.multipliedReportingOverflow(by: steps).partialValue
                        / progress.bytesTotal))
        var last = lastStep.load(ordering: .relaxed)
        while step > last {
            let (exchanged, original) = lastStep.compareExchange(
                expected: last, desired: step, ordering: .relaxed)
            if exchanged { return true }
            last = original
        }
        return false
    }
}
