import DMGReader
import DiskImage
import Dispatch
import Extractor
import Foundation
import Mounter
import Synchronization
import Verifier

/// How a session stages and installs.
public struct InstallOptions: Sendable {
    /// Where the app goes, usually `/Applications`. Staging happens on its volume, so
    /// installing is a rename.
    public var destination: URL
    /// `.background` while the popup shows ("ready before you click"); `.userInitiated`
    /// when the user already asked to install (a manual open). Low Power Mode and heat are
    /// handled by `conditions`, not here.
    public var stagingPriority: StageOptions.Priority
    /// The image's decode policy while a background session reads and stages (from the
    /// catalog walk on). Install boosts it to `.fast`. `.utility` by default; injectable so
    /// the impact benchmark can compare presets.
    public var backgroundDecodePolicy: DecodePolicy
    /// The "Skip the 'downloaded from the Internet' prompt" setting. When on, a notarized
    /// app that passes the check gets its quarantine written pre-approved.
    public var skipFirstLaunchPrompt: Bool
    /// Moves the replaced copy on an update to the Trash. The app passes
    /// `FileManager.trashItem`; tests pass a folder of their own.
    public var trash: @Sendable (URL) throws -> Void
    /// Told when the session falls back to the hidden mount, with the reader's reason. For
    /// diagnostics only; the session carries on by itself.
    public var mountFallback: (@Sendable (_ dmg: URL, _ reason: ReaderError) -> Void)?
    /// Low Power Mode and thermal pressure: while constrained, a background session waits
    /// in `waitingToPrepare` instead of staging. `.system` in the app; tests inject their own.
    public var conditions: StagingConditions
    /// Background staging's write tuning (`StageOptions.uncachedBackgroundWrites` and
    /// `backgroundWriteRate`). Injectable so the impact benchmark can compare them.
    public var uncachedBackgroundWrites: Bool
    public var backgroundWriteRate: Int?
    /// When Install is clicked while the signature check runs at utility QoS, cancel it
    /// and start again at user-initiated rather than wait for it. A running check's thread
    /// can't be raised from outside, and Code Signing's hashing inherits its QoS.
    public var reissuesVerificationOnBoost: Bool
    /// Where hidden mounts go: `HiddenMount.defaultRoot` in the app; tests use their own,
    /// so a test sweep never touches the app's mounts.
    public var mountRoot: URL = HiddenMount.defaultRoot
    /// For timing tests: take the hidden mount even for an image the reader handles.
    var forceMountFallback = false
    /// The signature check. Tests replace it to hold a check open; the app never does.
    var verify: @Sendable (_ app: URL, _ qos: DispatchQoS.QoSClass) async -> Verdict = {
        await Verifier.verdict(app: $0, qos: $1)
    }
    /// Which volume a folder is on, for `changeDestination`: two folders with the same value
    /// can share a staged copy. `URLResourceKey.volumeIdentifierKey` in the app; tests
    /// replace it to pretend a scratch folder is another volume (tests never mount one).
    var volumeIdentity: @Sendable (URL) -> String? = { url in
        // A fresh URL, so no cached resource value from an earlier lookup is reused.
        let fresh = URL(filePath: url.path, directoryHint: .isDirectory)
        return (try? fresh.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map {
            String(describing: $0)
        }
    }

    public init(
        destination: URL, stagingPriority: StageOptions.Priority = .background,
        backgroundDecodePolicy: DecodePolicy = .utility, skipFirstLaunchPrompt: Bool = false,
        trash: @escaping @Sendable (URL) throws -> Void,
        mountFallback: (@Sendable (_ dmg: URL, _ reason: ReaderError) -> Void)? = nil,
        conditions: StagingConditions = .system, uncachedBackgroundWrites: Bool = false,
        backgroundWriteRate: Int? = Extractor.defaultBackgroundWriteRate, reissuesVerificationOnBoost: Bool = true
    ) {
        self.destination = destination
        self.stagingPriority = stagingPriority
        self.backgroundDecodePolicy = backgroundDecodePolicy
        self.skipFirstLaunchPrompt = skipFirstLaunchPrompt
        self.trash = trash
        self.mountFallback = mountFallback
        self.conditions = conditions
        self.uncachedBackgroundWrites = uncachedBackgroundWrites
        self.backgroundWriteRate = backgroundWriteRate
        self.reissuesVerificationOnBoost = reissuesVerificationOnBoost
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

    /// Every state is published with the installed copy as it is at the current
    /// destination, once `changeDestination` has looked there (`installedCopy`).
    public private(set) var state: InstallState {
        get { published }
        set {
            published = installedCopy.map { newValue.replacingUpdate($0) } ?? newValue
            continuation.yield(published)
            if published.isFinal { continuation.finish() }
        }
    }
    private var published: InstallState = .reading
    /// Where the app goes: `options.destination` until `changeDestination(_:)`.
    public private(set) var destination: URL
    /// The installed copy at `destination`, read again after each destination change (and
    /// once the verdict is known); nil until the first change, when the pipeline's own read
    /// stands. `.some(nil)` means no copy there.
    private var installedCopy: AppSummary.Update??
    /// The staged copy's verdict, kept so a destination change never checks again.
    private var verdict: Verdict?
    /// True once the pipeline has published `ready` or `warning`: from then on a destination
    /// change moves the staged copy itself, instead of leaving it to the pipeline's end.
    private var settled = false
    /// The rename into place has begun; the destination is fixed from here.
    private var moving = false
    /// Destination changes run one after another; `install()` and `cancel()` wait for them.
    private var switchTask: Task<Void, Never>?
    /// For tests and the app's log: how long the last `changeDestination` took, and how many
    /// times the staged copy was copied to another volume.
    public private(set) var lastDestinationChange: Duration?
    private(set) var relocations = 0
    public private(set) var timings = InstallTimings()

    private let continuation: AsyncStream<InstallState>.Continuation
    private let job = StagingJob()
    private let stopFlag = Flag()
    private let clock = ContinuousClock()
    private var startedAt: ContinuousClock.Instant?
    private var runTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var licenceAnswer: CheckedContinuation<Bool, Never>?
    /// The user agreed to the licence Drop showed; the hidden mount may then answer the
    /// attach tool's licence prompt.
    private var licenceAccepted = false
    private var passwordAnswer: CheckedContinuation<MountPassword?, Never>?
    /// The hidden mount while the image is attached.
    private(set) var mount: HiddenMount?
    /// Set once the user clicked Install; `run` installs as soon as the verdict allows.
    private var installRequested = false
    private var summary: AppSummary?
    /// The licence screen's early read, reused once the licence is accepted.
    private var early: EarlyRead?
    private var staged: StagedApp?
    /// For tests: the area being written, and the image's device.
    private(set) var stagingArea: StagingArea?
    private var device: UDIFDevice?
    /// The latest progress, kept while `waitingToPrepare` hides it.
    private var lastProgress = InstallProgress(bytesDone: 0, bytesTotal: 0)
    /// Watches `options.conditions` while staging and the check run.
    private var conditionsTask: Task<Void, Never>?
    /// `run` waiting for the constraint to lift (or Install) before the signature check.
    private var unconstrainedWaiters: [CheckedContinuation<Void, Never>] = []
    /// The signature check in flight and its QoS, so a boost can reissue it.
    private var verification: (task: Task<Verdict, Never>, qos: DispatchQoS.QoSClass)?
    private var reissueVerification = false
    /// For tests: the QoS of every signature check started, in order.
    private(set) var verificationQoS: [DispatchQoS.QoSClass] = []

    public init(dmg: URL, options: InstallOptions) {
        self.dmg = dmg
        self.options = options
        destination = options.destination
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

    /// Answers `needsPassword`: attaches the encrypted image with it. A wrong one comes back
    /// as `needsPassword` with the next attempt number. The password is zeroed once the
    /// attach tool has read it. Does nothing in any other state.
    public func providePassword(_ password: MountPassword) {
        guard case .needsPassword = state, let answer = passwordAnswer else { return }
        passwordAnswer = nil
        answer.resume(returning: password)
    }

    /// `providePassword(_:)` from a string, for a text field's value.
    public func providePassword(_ password: String) { providePassword(MountPassword(password)) }

    /// Installs. While identified or preparing, this boosts staging to full speed and installs once the
    /// app is staged and checked (unless the check ends in a warning or refusal: see
    /// `InstallState`). In `warning` it is Install Anyway. Elsewhere it does nothing.
    /// Returns once the session settles: installed, failed, or waiting in `warning`.
    public func install() async {
        // A destination change in flight finishes first: the staged copy may be on its way
        // to the new volume.
        await switchTask?.value
        switch state {
        case .identified(let summary), .preparing(let summary, _), .waitingToPrepare(let summary):
            installRequested = true
            timings.boosted = elapsed()
            job.boost()
            state = .installing(summary, lastProgress)
            wakeUnconstrainedWaiters()
            if let verification, verification.qos != .userInitiated, options.reissuesVerificationOnBoost {
                reissueVerification = true
                verification.task.cancel()
            }
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
        job.resume()
        wakeUnconstrainedWaiters()
        answerLicence(false)
        answerPassword(nil)
        runTask?.cancel()
        await switchTask?.value
        await runTask?.value
        await installTask?.value
        if let staged {
            self.staged = nil
            await Self.discard(staged.area)
        }
        if !state.isFinal { state = .cancelled }
    }

    /// Returns once the pipeline has stopped, including the hidden mount's detach, which
    /// runs just after the final state is published.
    public func waitUntilDone() async {
        await runTask?.value
        await installTask?.value
    }

    /// The popup's Not now: the same as `cancel()`.
    public func notNow() async { await cancel() }

    /// Installs into `url` instead, without starting over: the licence is never asked again
    /// and the image isn't read again.
    ///
    /// - Always looks at the installed copy in `url` (its version, and once the verdict is
    ///   known its developer against the staged app's) and publishes the current state with
    ///   it, so the panel switches between a new install and an update.
    /// - Staged copy on the same volume as `url`: kept as it is, with its ticket, quarantine
    ///   and verdict. Nothing else runs; the rename at install works from any folder there.
    /// - Another volume: copied into a new staging area there (`Extractor.copy`), its
    ///   cdhashes checked against the verdict's, then the old area is deleted. No new
    ///   signature check.
    /// - Still staging or checking: the pipeline carries on into the area it has, and moves
    ///   the copy (by the rule above) when the verdict is in, before `ready` or `warning`.
    ///
    /// Changes run one at a time, in order; `install()` and `cancel()` wait for the one in
    /// flight, and `cancel()` stops a copy between files and deletes both areas. Ignored
    /// once installing has begun or the session has ended.
    public func changeDestination(_ url: URL) async {
        guard !state.isFinal, !moving, installTask == nil, url.standardizedFileURL != destination.standardizedFileURL
        else { return }
        let started = clock.now
        destination = url
        let previous = switchTask
        let task = Task {
            await previous?.value
            await self.applyDestination()
        }
        switchTask = task
        await task.value
        lastDestinationChange = clock.now - started
    }

    private func applyDestination() async {
        guard !stopFlag.isSet, !state.isFinal, !moving else { return }
        if settled {
            guard await settleDestination() else { return }
        } else {
            guard let bundleName = summary?.bundleName ?? early?.app.name else { return }
            let target = destination
            let update = await Self.readInstalledCopy(in: target, bundleName: bundleName, verdict: verdict)
            // A later change reads again, and a pipeline that settled meanwhile read this
            // destination itself, against the verdict.
            guard target == destination, !settled, !state.isFinal else { return }
            installedCopy = .some(update)
            summary?.update = update
            early?.summary.update = update
        }
        // Publish the current state again, with the installed copy at the new destination.
        state = state
    }

    /// Moves the staged copy to the destination's volume if it isn't there, then reads the
    /// installed copy against the verdict. Loops while the destination changes under it.
    /// False when the move failed (the session is then `failed`) or the session stopped.
    private func settleDestination() async -> Bool {
        while true {
            let target = destination
            if let staged, !onSameVolume(staged.area.url, target) {
                guard await relocate(staged, to: target) else { return false }
            }
            guard let bundleName = summary?.bundleName else { return true }
            let update = await Self.readInstalledCopy(
                in: target, bundleName: bundleName, verdict: verdict)
            guard !stopFlag.isSet else { return false }
            guard target == destination else { continue }
            installedCopy = .some(update)
            summary?.update = update
            return true
        }
    }

    private func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let first = options.volumeIdentity(a), let second = options.volumeIdentity(b) else { return false }
        return first == second
    }

    /// Copies the staged app to `target`'s volume, checks the copy is the code the verdict
    /// covers, and swaps it in for the old area, which is deleted.
    private func relocate(_ old: StagedApp, to target: URL) async -> Bool {
        let stop = stopFlag
        let expected = verdict?.signing?.cdhashes ?? []
        let qos: QualityOfService = isFast ? .userInitiated : .utility
        let moved: StagedApp
        do {
            moved = try await Self.onThread(qos: qos) {
                try Extractor.copy(old, toVolumeOf: target, isCancelled: { stop.isSet })
            }
        } catch {
            if stop.isSet { return false }
            await fail(InstallFailure(error))
            return false
        }
        let url = moved.url
        let copied = (try? await Self.onThread(qos: qos) { try Verifier.signingInfo(app: url) })?.cdhashes ?? []
        guard copied == expected else {
            await Self.discard(moved.area)
            await fail(.other("The copy on the new volume doesn't match the checked app."))
            return false
        }
        guard !stop.isSet else {
            await Self.discard(moved.area)
            return false
        }
        staged = moved
        stagingArea = moved.area
        relocations += 1
        await Self.discard(old.area)
        return true
    }

    /// Ends the session `failed`, deleting the staged copy first.
    private func fail(_ failure: InstallFailure) async {
        if let staged {
            self.staged = nil
            await Self.discard(staged.area)
        }
        if !state.isFinal { state = .failed(failure) }
    }

    /// The installed copy named `bundleName` in `destination`: nil when there is none,
    /// else its version and, once there is a `verdict`, whether the same developer signed it.
    static func readInstalledCopy(in destination: URL, bundleName: String, verdict: Verdict?) async
        -> AppSummary.Update?
    {
        let installed = destination.appending(path: bundleName, directoryHint: .isDirectory)
        return try? await onThread(qos: .userInitiated) { () -> AppSummary.Update? in
            var status = stat()
            guard lstat(installed.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return nil }
            var update = AppSummary.Update(
                installedVersion: BundleInfo.read(installedApp: installed)?.shortVersion, developer: nil)
            if let verdict {
                if let new = verdict.signing, let signing = try? Verifier.signingInfo(app: installed) {
                    update.developer = Verifier.sameDeveloper(new: new, installed: signing)
                } else {
                    // The installed copy's signature couldn't be read: nothing to compare against.
                    update.developer = .installedUnsigned
                }
            }
            return update
        } ?? nil
    }

    /// The image device's decode policy right now; nil for raw images or before staging.
    var decodePolicy: DecodePolicy? { device?.decodePolicy }

    // MARK: - The pipeline

    private func run() async {
        if options.forceMountFallback { return await runMounted(.unsupportedContainer("forced by the options")) }
        let opened: OpenedImage
        let app: Entry
        do {
            let path = dmg.path
            // Opening and the first reads are small and the popup is already up waiting for
            // them: user-initiated, at the device's fast policy. The background policy starts
            // once the app is named (`identify`).
            opened = try await Self.onThread(qos: .userInitiated) { try DMGReader.open(path: path) }
            timings.opened = elapsed()
            if let licence = opened.image.licence {
                let fileSystem = opened.fileSystem
                let destination = self.destination
                let read = try? await Self.onThread(qos: .userInitiated) {
                    Self.identifySingleApp(in: fileSystem, destination: destination)
                }
                early = read
                state = .needsLicence(licence, preview: read.map { AppPreview($0.summary) })
                if !isFast { opened.image.udif?.decodePolicy = options.backgroundDecodePolicy }
                if let read {
                    let size = try? await Self.onThread(qos: .utility) { try Self.size(of: read.app, in: fileSystem) }
                    if let size, case .needsLicence(let shown, var preview?) = state {
                        preview.size = size
                        early?.summary.size = size
                        state = .needsLicence(shown, preview: preview)
                    }
                }
                guard await waitForLicence() else { return finishCancelled() }
                licenceAccepted = true
            }
            guard !stopFlag.isSet else { return finishCancelled() }
            guard let chosen = try chooseApp(in: opened.fileSystem) else { return }
            app = chosen
        } catch let error as ReaderError where error.wantsMountFallback {
            return await runMounted(error)
        } catch {
            return finish(with: error)
        }
        await identifyAndStage(app, from: opened.fileSystem, udif: opened.image.udif)
    }

    /// The hidden-mount fallback: licence (when readable), password (when encrypted),
    /// attach, then the same staging and check as the direct path. The image is detached
    /// once staged, and whatever happens before then, when this returns.
    private func runMounted(_ reason: ReaderError) async {
        options.mountFallback?(dmg, reason)
        await attachAndStage()
        await detachMount()
    }

    private func attachAndStage() async {
        let path = dmg.path
        if !licenceAccepted,
            let licence = try? await Self.onThread(qos: .utility, { try DiskImage.licence(atPath: path) })
        {
            state = .needsLicence(licence, preview: nil)
            guard await waitForLicence() else { return finishCancelled() }
            licenceAccepted = true
        }
        let encrypted = DiskImage.isEncrypted(path: path)
        let image = dmg
        let root = options.mountRoot
        let accepted = licenceAccepted
        var attempt = 0
        let mount: HiddenMount
        while true {
            guard !stopFlag.isSet else { return finishCancelled() }
            var password: MountPassword?
            if encrypted {
                attempt += 1
                state = .needsPassword(attempt: attempt)
                guard let given = await waitForPassword(), !stopFlag.isSet else { return finishCancelled() }
                password = given
                state = .reading
            }
            do {
                let secret = password
                mount = try await Self.onThread(qos: isFast ? .userInitiated : .utility) {
                    defer { secret?.wipe() }
                    return try HiddenMount.attach(image, password: secret, licenceAccepted: accepted, root: root)
                }
                break
            } catch MountError.wrongPassword where encrypted {
                continue
            } catch MountError.licenceNotShown {
                state = .cannotInstall(.licenceNotShown)
                return
            } catch {
                state = .cannotInstall(.wontAttach(String(describing: error)))
                return
            }
        }
        self.mount = mount
        timings.mounted = elapsed()
        timings.opened = timings.opened ?? timings.mounted
        guard !stopFlag.isSet else { return finishCancelled() }
        let app: Entry
        let fileSystem: MountedFileSystem
        do {
            fileSystem = try await Self.onThread(qos: .userInitiated) { try mount.fileSystem() }
            guard let chosen = try chooseApp(in: fileSystem) else { return }
            app = chosen
        } catch {
            return finish(with: error)
        }
        await identifyAndStage(app, from: fileSystem, udif: nil)
    }

    /// Detaches the hidden mount, if one is attached. A detach that fails even when forced
    /// leaves the image to `HiddenMount.sweepLeftoverMounts()` at the next launch.
    private func detachMount() async {
        guard let mount else { return }
        self.mount = nil
        _ = try? await Self.onThread(qos: .utility) { try mount.detach() }
        timings.unmounted = elapsed()
    }

    /// Names the app (`identified`), then stages and checks it, from whichever filesystem
    /// holds it. The first read is small and runs at user-initiated priority on the device's
    /// current policy; the size walk and everything after run at the background policy.
    private func identifyAndStage(_ app: Entry, from fileSystem: any FileSystem, udif: UDIFDevice?) async {
        let destination = self.destination
        var summary: AppSummary
        if let early, early.app.name == app.name, mount == nil {
            summary = early.summary
        } else {
            summary =
                await
                (try? Self.onThread(qos: .userInitiated) {
                    Self.identify(app: app, in: fileSystem, destination: destination)
                })
                ?? AppSummary(
                    bundleName: app.name, name: app.name.trimmingAppSuffix, version: nil, bundleIdentifier: nil,
                    size: nil)
        }
        early = nil
        if destination != self.destination {
            // Changed while naming the app: look at the installed copy where it now goes.
            let update = await Self.readInstalledCopy(in: self.destination, bundleName: app.name, verdict: nil)
            installedCopy = .some(update)
            summary.update = update
        }
        self.summary = summary
        timings.identified = elapsed()
        state =
            installRequested
            ? .installing(summary, InstallProgress(bytesDone: 0, bytesTotal: summary.size ?? 0))
            : .identified(summary)
        if !isFast { udif?.decodePolicy = options.backgroundDecodePolicy }
        guard !stopFlag.isSet else { return finishCancelled() }
        await prepareAndStage(app, summary: summary, from: fileSystem, udif: udif)
    }

    /// Staging, the check and the verdict, from whichever filesystem holds the app.
    private func prepareAndStage(
        _ app: Entry, summary identified: AppSummary, from fileSystem: any FileSystem, udif: UDIFDevice?
    ) async {
        let destination = self.destination
        let dmgURL = dmg
        let prepared: Prepared
        do {
            prepared = try await Self.onThread(qos: isFast ? .userInitiated : .utility) {
                try Prepared.make(
                    app: app, summary: identified, fileSystem: fileSystem, destination: destination, dmg: dmgURL)
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
        lastProgress = InstallProgress(bytesDone: 0, bytesTotal: summary.size ?? 0)
        state = installRequested ? .installing(summary, lastProgress) : .preparing(summary, lastProgress)
        watchConditions()
        defer {
            conditionsTask?.cancel()
            conditionsTask = nil
        }

        let staged: StagedApp
        do {
            staged = try await stage(
                app, from: fileSystem, udif: udif, into: prepared.area, quarantine: prepared.quarantine)
        } catch let error as ReaderError where error.wantsMountFallback && mount == nil {
            // A decmpfs file found while planning: nothing was written yet.
            conditionsTask?.cancel()
            conditionsTask = nil
            return await runMounted(error)
        } catch {
            return finish(with: error)
        }
        self.staged = staged
        timings.staged = elapsed()
        // The staged copy is complete: the image isn't needed for the check or the install.
        await detachMount()
        await waitUntilUnconstrained()
        guard !stopFlag.isSet else { return finishCancelled() }

        // Staple before the check, so Gatekeeper's answer (and an offline first launch)
        // sees the ticket. Best effort: a failure only means macOS fetches it online.
        if let ticket = prepared.ticket {
            let url = staged.url
            _ = try? await Self.onThread(qos: isFast ? .userInitiated : .utility) {
                try Verifier.staple(ticket, into: url)
            }
        }

        let verdict = await verifyBoostable(staged.url)
        timings.verified = elapsed()
        guard !stopFlag.isSet, !Task.isCancelled else { return finishCancelled() }

        self.verdict = verdict
        summary.signer = verdict.signing?.organisation ?? verdict.signing?.signer
        summary.teamID = verdict.signing?.teamID
        summary.isNotarized = verdict.assessment?.assessment?.isCheckedByApple == true
        self.summary = summary

        if options.skipFirstLaunchPrompt, verdict.allowsPreApproval {
            // On failure the app keeps plain quarantine: macOS shows its usual prompt.
            _ = try? await Self.onThread(qos: isFast ? .userInitiated : .utility) { try Extractor.markApproved(staged) }
        }

        if case .refuse = verdict.decision {
            self.staged = nil
            Extractor.discard(staged)
        }
        // Reads the installed copy's developer against the verdict. The destination may also
        // have changed while staging and checking: then the staged copy goes to its volume
        // and the installed copy is read there (`changeDestination`).
        guard await settleDestination(), let latest = self.summary else { return }
        summary = latest
        switch verdict.decision {
        case .install:
            // Install already clicked: stay in `installing` rather than flash `ready`.
            if installRequested {
                await moveIntoPlace()
            } else {
                state = .ready(summary)
                settled = true
            }
        case .warn(let warning):
            installRequested = false
            state = .warning(summary, warning)
            settled = true
        case .refuse(let refusal):
            state = .refused(summary, refusal)
        }
    }

    /// True once nothing should hold back: Install was clicked, or the session was made
    /// to run at user-initiated priority from the start.
    private var isFast: Bool { installRequested || options.stagingPriority == .userInitiated }

    /// Runs the signature check at the session's current priority. If Install boosts the
    /// session while a utility-QoS check runs, `install()` cancels it and this starts it
    /// again at user-initiated (measured faster than waiting: `impact-bench.md`, round 2).
    private func verifyBoostable(_ app: URL) async -> Verdict {
        let verify = options.verify
        while true {
            let qos: DispatchQoS.QoSClass = isFast ? .userInitiated : .utility
            let task = Task { await verify(app, qos) }
            verification = (task, qos)
            verificationQoS.append(qos)
            let verdict = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            verification = nil
            guard reissueVerification, !stopFlag.isSet, !Task.isCancelled else { return verdict }
            reissueVerification = false
        }
    }

    // MARK: - Low Power Mode and thermal state

    /// Starts following `options.conditions` for a background session, and applies the
    /// current value at once.
    private func watchConditions() {
        guard !isFast else { return }
        let conditions = options.conditions
        applyConditions()
        conditionsTask = Task { [weak self] in
            for await _ in conditions.changes() {
                guard let self else { return }
                await self.applyConditions()
            }
        }
    }

    /// Pauses the job between files and shows `waitingToPrepare` while constrained;
    /// resumes and goes back to `preparing` when not. Nothing once Install was clicked.
    private func applyConditions() {
        guard !isFast, !stopFlag.isSet else { return }
        if options.conditions.isConstrained() {
            job.pause()
            if case .preparing(let summary, _) = state { state = .waitingToPrepare(summary) }
        } else {
            job.resume()
            if case .waitingToPrepare(let summary) = state { state = .preparing(summary, lastProgress) }
            wakeUnconstrainedWaiters()
        }
    }

    /// Returns at once unless the job is paused; then waits for the constraint to lift,
    /// Install or cancel.
    private func waitUntilUnconstrained() async {
        guard job.isPaused, !isFast, !stopFlag.isSet else { return }
        await withCheckedContinuation { unconstrainedWaiters.append($0) }
    }

    private func wakeUnconstrainedWaiters() {
        let waiters = unconstrainedWaiters
        unconstrainedWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// The early read: the app's `Info.plist` and icon from the image, and the installed
    /// copy's version from the destination (an `lstat` and a small plist). No size (nil),
    /// no signatures. Shown as `identified`, and on the licence screen as its preview.
    static func identify(app: Entry, in fileSystem: any FileSystem, destination: URL) -> AppSummary {
        let info = BundleInfo.read(app: app, in: fileSystem)
        var summary = AppSummary(
            bundleName: app.name, name: info?.displayName ?? app.name.trimmingAppSuffix, version: info?.shortVersion,
            bundleIdentifier: info?.identifier, size: nil, iconData: info?.iconData(app: app, in: fileSystem),
            buildVersion: info?.buildVersion)
        let installed = destination.appending(path: app.name, directoryHint: .isDirectory)
        var status = stat()
        if lstat(installed.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
            summary.update = AppSummary.Update(
                installedVersion: BundleInfo.read(installedApp: installed)?.shortVersion, developer: nil)
        }
        return summary
    }

    /// `identify` for the licence screen, when the image holds exactly one app.
    static func identifySingleApp(in fileSystem: any FileSystem, destination: URL) -> EarlyRead? {
        guard let apps = try? DMGReader.apps(in: fileSystem), apps.count == 1, let app = apps.first else {
            return nil
        }
        return EarlyRead(app: app, summary: identify(app: app, in: fileSystem, destination: destination))
    }

    /// Sum of the app's file sizes, from the catalog.
    static func size(of app: Entry, in fileSystem: any FileSystem) throws -> UInt64 {
        var size: UInt64 = 0
        try DMGReader.walk(fileSystem, from: app) { _, entry in
            if entry.kind == .file { size &+= entry.size }
        }
        return size
    }

    /// The single top-level app, or nil after setting `cannotInstall`.
    private func chooseApp(in fileSystem: any FileSystem) throws -> Entry? {
        let apps = try DMGReader.apps(in: fileSystem)
        if apps.count == 1, let app = apps.first { return app }
        if apps.count > 1 {
            state = .cannotInstall(.multipleApps(names: apps.map(\.name).sorted()))
            return nil
        }
        let packages = try DMGReader.packages(in: fileSystem)
        state = .cannotInstall(packages.isEmpty ? .noApp : .packageOnly(names: packages.map(\.name).sorted()))
        return nil
    }

    private func stage(
        _ app: Entry, from fileSystem: any FileSystem, udif device: UDIFDevice?, into area: StagingArea,
        quarantine: String?
    ) async throws -> StagedApp {
        self.device = device
        let background = options.stagingPriority == .background && !job.isBoosted
        device?.decodePolicy = background ? options.backgroundDecodePolicy : .fast
        timings.stagingStarted = elapsed()

        let stop = stopFlag
        let throttle = ProgressThrottle(steps: Self.progressSteps)
        let stageOptions = StageOptions(
            quarantine: quarantine, priority: options.stagingPriority, isCancelled: { stop.isSet }, job: job,
            onBoost: { device?.decodePolicy = .fast }, uncachedBackgroundWrites: options.uncachedBackgroundWrites,
            backgroundWriteRate: options.backgroundWriteRate)
        return try await Self.onThread(qos: background ? .background : .userInitiated) {
            try Extractor.stage(app: app, from: fileSystem, into: area, options: stageOptions) { progress in
                guard throttle.shouldEmit(progress) else { return }
                Task { await self.progressed(progress) }
            }
        }
    }

    private func progressed(_ progress: StageProgress) {
        let next = InstallProgress(bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal)
        if next.bytesDone > lastProgress.bytesDone { lastProgress = next }
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
        moving = true
        state = .installing(summary, InstallProgress(bytesDone: summary.size ?? 0, bytesTotal: summary.size ?? 0))
        let destination = self.destination
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
        case let error as MountError:
            state = .cannotInstall(.wontAttach(String(describing: error)))
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

    private func waitForPassword() async -> MountPassword? {
        guard !stopFlag.isSet else { return nil }
        return await withCheckedContinuation { passwordAnswer = $0 }
    }

    private func answerPassword(_ password: MountPassword?) {
        guard let answer = passwordAnswer else { return }
        passwordAnswer = nil
        answer.resume(returning: password)
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
    /// The QoS is set from inside the thread with `pthread_set_qos_class_self_np` rather than
    /// `Thread.qualityOfService`, which fixes it for the thread's life: `Extractor.stage`
    /// raises its calling thread on a boost (see `WorkerPriority` in the Extractor).
    static func onThread<T: Sendable>(
        qos: QualityOfService, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let qosClass = qosClass(qos)
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                pthread_set_qos_class_self_np(qosClass, 0)
                continuation.resume(with: Result { try body() })
            }
            thread.start()
        }
    }

    private static func qosClass(_ qos: QualityOfService) -> qos_class_t {
        switch qos {
        case .userInteractive: QOS_CLASS_USER_INTERACTIVE
        case .userInitiated: QOS_CLASS_USER_INITIATED
        case .utility: QOS_CLASS_UTILITY
        case .background: QOS_CLASS_BACKGROUND
        default: QOS_CLASS_DEFAULT
        }
    }

    static func discard(_ area: StagingArea) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Extractor.discard(area) { continuation.resume() }
        }
    }
}

/// The app chosen in an image and what `InstallSession.identify` read about it.
struct EarlyRead: Sendable {
    var app: Entry
    var summary: AppSummary
}

/// Everything read after `identified` and before staging starts, in one blocking pass off
/// the actor at the background policy: the size walk, the ticket, the quarantine and the
/// staging area. The installed copy's signature is read once the verdict is in.
private struct Prepared: Sendable {
    var summary: AppSummary
    var ticket: NotarizationTicket?
    var quarantine: String?
    var area: StagingArea

    static func make(
        app: Entry, summary identified: AppSummary, fileSystem: any FileSystem, destination: URL, dmg: URL
    ) throws -> Prepared {
        var summary = identified
        summary.size = try summary.size ?? InstallSession.size(of: app, in: fileSystem)

        // A DMG without a ticket, or one this code can't parse, just means nothing to staple.
        let ticket = try? Verifier.ticket(fromDMG: dmg.path)
        let quarantine = try Quarantine.read(at: dmg)
        let area = try Extractor.makeStagingArea(for: destination)
        return Prepared(
            summary: summary, ticket: ticket,
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

extension String {
    /// "Rectangle.app" → "Rectangle".
    var trimmingAppSuffix: String { hasSuffix(".app") ? String(dropLast(".app".count)) : self }
}
