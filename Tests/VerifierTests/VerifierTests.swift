import Foundation
import Security
import Testing

@testable import Verifier

@Suite struct SigningInfoTests {
    @Test(arguments: Fixtures.notarized + [Fixtures.developmentSigned])
    func teamIDMatchesCodesign(name: String) throws {
        let info = try Verifier.signingInfo(app: try Fixtures.real(name))
        let expected = try Fixtures.codesignTeamID(name)
        #expect(info.teamID != nil)
        #expect(info.teamID == expected)
        #expect(info.identifier != nil)
        #expect(info.hardenedRuntime)
        #expect(info.anchoredToApple)
        #expect(!info.cdhashes.isEmpty)
        #expect(info.cdhashes.allSatisfy { $0.bytes.count == CDHash.length })
    }

    @Test(arguments: Fixtures.notarized)
    func notarizedAppsAreDeveloperID(name: String) throws {
        let info = try Verifier.signingInfo(app: try Fixtures.real(name))
        #expect(info.kind == .developerID)
        let teamID = try #require(info.teamID)
        #expect(info.signer?.hasPrefix("Developer ID Application: ") == true)
        #expect(info.signer?.hasSuffix("(\(teamID))") == true)
        #expect(info.organisation?.isEmpty == false)
    }

    @Test func rectangleDetails() throws {
        let info = try Verifier.signingInfo(app: try Fixtures.real("Rectangle"))
        #expect(info.identifier == "com.knollsoft.Rectangle")
        #expect(info.signer == "Developer ID Application: Ryan Hanson (XSYZ3E4B7D)")
        #expect(info.organisation == "Ryan Hanson")
        // From `codesign -dvvv`: CDHash=92fb336be707409ef5bc0f056b8245566becccf1.
        #expect(info.cdhashes.map(\.hex).contains("92fb336be707409ef5bc0f056b8245566becccf1"))
        #expect(!info.hasStapledTicket)
    }

    @Test func universalAppListsEverySlice() throws {
        // Rectangle is universal (x86_64 + arm64); each slice has its own cdhash.
        let app = try Fixtures.real("Rectangle")
        let architectures = Bundle(url: app)?.executableArchitectures ?? []
        try #require(architectures.count > 1)
        let info = try Verifier.signingInfo(app: app)
        #expect(Set(info.cdhashes).count >= architectures.count)
    }

    @Test(arguments: ["Stats", "MonitorControl", "Clipy", "Slack", "Firefox"])
    func stapledAppsReportTicket(name: String) throws {
        #expect(try Verifier.signingInfo(app: try Fixtures.real(name)).hasStapledTicket)
    }

    @Test func developmentSigned() throws {
        let info = try Verifier.signingInfo(app: try Fixtures.real(Fixtures.developmentSigned))
        #expect(info.kind == .otherAppleIssued)
        #expect(info.signer?.hasPrefix("Apple Development: ") == true)
    }

    @Test func adHoc() throws {
        let info = try Verifier.signingInfo(app: try Fixtures.synthetic("AdHoc"))
        #expect(info.kind == .adHoc)
        #expect(info.teamID == nil)
        #expect(info.signer == nil)
        #expect(info.identifier == "dev.niduslabs.drop.fixture.tiny")
        #expect(!info.cdhashes.isEmpty)
        #expect(!info.anchoredToApple)
    }

    @Test func unsigned() throws {
        let info = try Verifier.signingInfo(app: try Fixtures.synthetic("Unsigned"))
        #expect(info.kind == .unsigned)
        #expect(info.cdhashes.isEmpty)
    }

    @Test func tamperedStillReportsSigner() throws {
        #expect(try Verifier.signingInfo(app: try Fixtures.synthetic("Tampered")).kind == .adHoc)
    }

    @Test func missingPathThrows() {
        #expect(throws: VerifierError.self) {
            try Verifier.signingInfo(app: Fixtures.root.appending(path: "nothing-here.app"))
        }
    }
}

@Suite struct ValidationTests {
    @Test(arguments: Fixtures.notarized + [Fixtures.developmentSigned])
    func realAppsAreValid(name: String) async throws {
        let validity = await Verifier.validate(app: try Fixtures.real(name))
        #expect(validity == .valid, "\(validity)")
    }

    @Test func synthetic() async throws {
        #expect(await Verifier.validate(app: try Fixtures.synthetic("AdHoc")) == .valid)
        #expect(await Verifier.validate(app: try Fixtures.synthetic("Unsigned")) == .unsigned)
        guard case .invalid(_, let status, let path) = await Verifier.validate(app: try Fixtures.synthetic("Tampered"))
        else {
            Issue.record("Tampered.app validated")
            return
        }
        #expect(status == errSecCSBadResource)
        #expect(path?.hasSuffix("note.txt") == true)
    }

    @Test func timeoutBoundsValidation() async throws {
        // Zed's main executable alone takes well over a millisecond to hash.
        let validity = await Verifier.validate(app: try Fixtures.real("Zed"), timeout: .milliseconds(1))
        #expect(validity == .notChecked(.timedOut))
    }

    @Test func cancellationStopsValidation() async throws {
        let app = try Fixtures.real("Zed")
        let task = Task { await Verifier.validate(app: app) }
        task.cancel()
        #expect(await task.value == .notChecked(.cancelled))
    }
}

@Suite struct AssessmentTests {
    @Test(arguments: Fixtures.notarized)
    func notarized(name: String) async throws {
        let assessment = try #require(await Verifier.assess(app: try Fixtures.real(name)).assessment)
        #expect(assessment.accepted)
        #expect(assessment.source == Assessment.Source.notarizedDeveloperID)
        #expect(assessment.isCheckedByApple)
    }

    @Test func rejected() async throws {
        for app in [try Fixtures.real(Fixtures.developmentSigned), try Fixtures.synthetic("AdHoc")] {
            let assessment = try #require(await Verifier.assess(app: app).assessment)
            #expect(!assessment.accepted)
            #expect(!assessment.isCheckedByApple)
        }
        let unsigned = try #require(await Verifier.assess(app: try Fixtures.synthetic("Unsigned")).assessment)
        #expect(unsigned.source == Assessment.Source.noUsableSignature)
        let tampered = try #require(await Verifier.assess(app: try Fixtures.synthetic("Tampered")).assessment)
        #expect(!tampered.accepted)
        #expect(tampered.status == errSecCSBadResource)
    }
}

@Suite struct VerdictTests {
    @Test(arguments: Fixtures.notarized)
    func notarizedInstalls(name: String) async throws {
        let verdict = await Verifier.verdict(app: try Fixtures.real(name))
        #expect(verdict.decision == .install)
        #expect(verdict.allowsPreApproval)
    }

    @Test func developmentSignedWarns() async throws {
        let verdict = await Verifier.verdict(app: try Fixtures.real(Fixtures.developmentSigned))
        #expect(verdict.decision == .warn(.notNotarized))
        #expect(!verdict.allowsPreApproval)
    }

    @Test func synthetic() async throws {
        #expect(await Verifier.verdict(app: try Fixtures.synthetic("AdHoc")).decision == .warn(.notNotarized))
        #expect(await Verifier.verdict(app: try Fixtures.synthetic("Unsigned")).decision == .warn(.unsigned))
        let tampered = await Verifier.verdict(app: try Fixtures.synthetic("Tampered"))
        guard case .refuse(.damaged(_, let status, _)) = tampered.decision else {
            Issue.record("Tampered.app: \(tampered.decision)")
            return
        }
        #expect(status == errSecCSBadResource)
        #expect(tampered.assessment == nil)
    }

    static let developerID = SigningInfo(
        kind: .developerID, identifier: "a", teamID: "TEAM1", signer: nil, organisation: nil,
        anchoredToApple: true, cdhashes: [], hardenedRuntime: true, hasStapledTicket: false)

    @Test func rules() {
        let notarized = AssessmentResult.assessed(
            Assessment(accepted: true, source: Assessment.Source.notarizedDeveloperID, status: nil))
        let plainDeveloperID = AssessmentResult.assessed(
            Assessment(accepted: true, source: Assessment.Source.developerID, status: nil))
        let revoked = AssessmentResult.assessed(
            Assessment(accepted: false, source: nil, status: errSecCSRevokedNotarization))
        let info = Self.developerID
        #expect(Verdict(signing: info, validity: .valid, assessment: notarized).decision == .install)
        #expect(Verdict(signing: info, validity: .valid, assessment: plainDeveloperID).decision == .warn(.notNotarized))
        #expect(Verdict(signing: info, validity: .valid, assessment: revoked).decision == .refuse(.revoked))
        #expect(
            Verdict(signing: info, validity: .valid, assessment: .notAssessed(.timedOut)).decision
                == .warn(.notarizationUnknown))
        #expect(
            Verdict(signing: info, validity: .valid, assessment: .unavailable).decision == .warn(.notarizationUnknown))
        #expect(
            Verdict(signing: info, validity: .notChecked(.timedOut), assessment: nil).decision
                == .refuse(.notChecked(.timedOut)))
        let damaged = Validity.invalid(reason: "x", status: errSecCSBadResource, path: nil)
        #expect(
            Verdict(signing: info, validity: damaged, assessment: notarized).decision
                == .refuse(.damaged(reason: "x", status: errSecCSBadResource, path: nil)))
    }
}

@Suite struct SameDeveloperTests {
    @Test func realApps() throws {
        let rectangle = try Verifier.signingInfo(app: try Fixtures.real("Rectangle"))
        let keePassXC = try Verifier.signingInfo(app: try Fixtures.real("KeePassXC"))
        let adHoc = try Verifier.signingInfo(app: try Fixtures.synthetic("AdHoc"))
        let unsigned = try Verifier.signingInfo(app: try Fixtures.synthetic("Unsigned"))
        #expect(Verifier.sameDeveloper(new: rectangle, installed: rectangle) == .same(teamID: "XSYZ3E4B7D"))
        #expect(
            Verifier.sameDeveloper(new: rectangle, installed: keePassXC)
                == .different(new: "XSYZ3E4B7D", installed: "G2S7P7J672"))
        #expect(Verifier.sameDeveloper(new: rectangle, installed: unsigned) == .installedUnsigned)
        #expect(Verifier.sameDeveloper(new: rectangle, installed: adHoc) == .installedUnsigned)
        #expect(Verifier.sameDeveloper(new: adHoc, installed: rectangle) == .newUnsigned(installed: "XSYZ3E4B7D"))
    }
}

@Suite struct TicketTests {
    @Test(arguments: ["Rectangle", "KeePassXC"])
    func extractsFromDMG(name: String) throws {
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg(name)))
        #expect(ticket.bytes.starts(with: NotarizationTicket.magic))
        #expect(!ticket.entries.isEmpty)
        let app = try Verifier.signingInfo(app: try Fixtures.real(name))
        #expect(Verifier.ticketCovers(ticket, app.cdhashes))
    }

    @Test func rectangleTicketMatchesSpike() throws {
        // The spike copied this DMG's ticket out by hand: 1926 bytes in a 0x78e wrapper blob.
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Rectangle")))
        #expect(ticket.bytes.count == 1926)
        #expect(ticket.entries.count == 14)
    }

    @Test func signedAndStapledDMG() throws {
        // Clipy's DMG is signed too, so the ticket slot follows the code directory and CMS slots.
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Clipy")))
        #expect(Verifier.ticketCovers(ticket, try Verifier.signingInfo(app: try Fixtures.real("Clipy")).cdhashes))
    }

    @Test(arguments: ["Stats", "MonitorControl", "boringNotch"])
    func unstapledDMGHasNone(name: String) throws {
        #expect(try Verifier.ticket(fromDMG: try Fixtures.dmg(name)) == nil)
    }

    @Test func coversOnlyItsOwnApp() throws {
        let rectangle = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Rectangle")))
        let keePassXC = try Verifier.signingInfo(app: try Fixtures.real("KeePassXC"))
        #expect(!Verifier.ticketCovers(rectangle, keePassXC.cdhashes))
        #expect(!Verifier.ticketCovers(rectangle, []))
    }

    @Test func appTicketParses() throws {
        let ticket = try #require(try Verifier.ticket(inApp: try Fixtures.real("Stats")))
        #expect(Verifier.ticketCovers(ticket, try Verifier.signingInfo(app: try Fixtures.real("Stats")).cdhashes))
    }

    @Test func rejectsGarbage() throws {
        #expect(throws: (any Error).self) {
            try NotarizationTicket(bytes: Array("s8ch".utf8) + [UInt8](repeating: 0, count: 12))
        }
        #expect(throws: (any Error).self) {
            try Verifier.ticket(inSuperBlob: [0xFA, 0xDE, 0x0C, 0xC0, 0, 0, 0, 12, 0, 0, 0, 9])
        }
        #expect(try Verifier.ticket(inSuperBlob: [0xFA, 0xDE, 0x0C, 0xC0, 0, 0, 0, 12, 0, 0, 0, 0]) == nil)
    }
}

@Suite struct StapleTests {
    @Test(arguments: Fixtures.dmgOnlyTicket)
    func staplesAndStillVerifies(name: String) async throws {
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg(name)))
        let (app, folder) = try Fixtures.copy(try Fixtures.real(name))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!(try Verifier.signingInfo(app: app).hasStapledTicket))

        try Verifier.staple(ticket, into: app)

        let file = Verifier.ticketURL(app: app)
        #expect(try Data(contentsOf: file) == Data(ticket.bytes))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == Int(Verifier.ticketFileMode))
        #expect(try Verifier.signingInfo(app: app).hasStapledTicket)
        let validate = try Fixtures.run("/usr/bin/xcrun", ["stapler", "validate", app.path])
        #expect(validate.status == 0, "\(validate.output)")
        let verify = try Fixtures.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        #expect(verify.status == 0, "\(verify.output)")
        #expect(await Verifier.validate(app: app) == .valid)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.appending(path: "Contents").path)
            .filter { $0.contains(".drop-") }
        #expect(leftovers.isEmpty)
    }

    /// Compares with what `xcrun stapler staple` writes (it fetches the current ticket from
    /// Apple, so this needs the network). Same file, same mode, same format, same cdhash.
    @Test func matchesStapler() throws {
        let dmgTicket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Rectangle")))
        let ours = try Fixtures.copy(try Fixtures.real("Rectangle"))
        let theirs = try Fixtures.copy(try Fixtures.real("Rectangle"))
        defer {
            try? FileManager.default.removeItem(at: ours.folder)
            try? FileManager.default.removeItem(at: theirs.folder)
        }
        try Verifier.staple(dmgTicket, into: ours.app)
        let staple = try Fixtures.run("/usr/bin/xcrun", ["stapler", "staple", theirs.app.path])
        try #require(staple.status == 0, "stapler staple (needs network): \(staple.output)")

        let ourFile = Verifier.ticketURL(app: ours.app)
        let theirFile = Verifier.ticketURL(app: theirs.app)
        let attributes = try FileManager.default.attributesOfItem(atPath: theirFile.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(
            try FileManager.default.attributesOfItem(atPath: ourFile.path)[.posixPermissions] as? Int
                == attributes[.posixPermissions] as? Int)
        let theirTicket = try #require(try Verifier.ticket(inApp: theirs.app))
        let cdhashes = try Verifier.signingInfo(app: ours.app).cdhashes
        #expect(theirTicket.covers(cdhashes))
        #expect(dmgTicket.covers(cdhashes))
    }

    @Test func refusesWhenAlreadyStapled() throws {
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Clipy")))
        let (app, folder) = try Fixtures.copy(try Fixtures.real("Clipy"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: Verifier.ticketURL(app: app))
        #expect(throws: Verifier.StapleError.alreadyStapled) { try Verifier.staple(ticket, into: app) }
        #expect(try Data(contentsOf: Verifier.ticketURL(app: app)) == before)
    }

    @Test func refusesTicketForAnotherApp() throws {
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Rectangle")))
        let (app, folder) = try Fixtures.copy(try Fixtures.real("KeePassXC"))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: Verifier.StapleError.notCovered) { try Verifier.staple(ticket, into: app) }
        #expect(!FileManager.default.fileExists(atPath: Verifier.ticketURL(app: app).path))
    }

    @Test func refusesOccupiedPath() throws {
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Rectangle")))
        let (app, folder) = try Fixtures.copy(try Fixtures.real("Rectangle"))
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(
            atPath: Verifier.ticketURL(app: app).path, withDestinationPath: "_CodeSignature/CodeResources")
        #expect(throws: Verifier.StapleError.pathOccupied) { try Verifier.staple(ticket, into: app) }
    }

    @Test func refusesUnsigned() throws {
        let ticket = try #require(try Verifier.ticket(fromDMG: try Fixtures.dmg("Rectangle")))
        let (app, folder) = try Fixtures.copy(try Fixtures.synthetic("Unsigned"))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: Verifier.StapleError.unsigned) { try Verifier.staple(ticket, into: app) }
    }
}

/// How long each call takes on the real apps. Opt-in: `DROP_TIMING=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROP_TIMING"] == "1"), .serialized)
struct TimingTests {
    @Test(arguments: Fixtures.notarized + [Fixtures.developmentSigned])
    func timings(name: String) async throws {
        let app = try Fixtures.real(name)
        let clock = ContinuousClock()
        let info = clock.measure { _ = try? Verifier.signingInfo(app: app) }
        let validate = await clock.measure { _ = await Verifier.validate(app: app) }
        let validateAgain = await clock.measure { _ = await Verifier.validate(app: app) }
        let assess = await clock.measure { _ = await Verifier.assess(app: app) }
        let spctl = await clock.measure {
            _ = await Verifier.$assessmentRoute.withValue(.spctlOnly) { await Verifier.assess(app: app) }
        }
        let ticket = clock.measure { _ = try? Verifier.ticket(fromDMG: try Fixtures.dmg(name)) }
        func ms(_ duration: Duration) -> String {
            String(
                format: "%.1f",
                Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
        }
        print(
            "timing \(name): signingInfo \(ms(info)) ms, validate \(ms(validate)) ms (again \(ms(validateAgain)) ms), "
                + "assess \(ms(assess)) ms, spctl \(ms(spctl)) ms, ticket \(ms(ticket)) ms")
    }
}

/// The `spctl` fallback `assess` uses when `SecAssessmentCreate` is missing or broken.
@Suite struct SpctlFallbackTests {
    /// A framework API whose `SecAssessmentCreate` fails without an error, as a stub of a
    /// removed or changed call might.
    static let brokenSPI: SecuritySPI.Assessment? = SecuritySPI.assessment.map { real in
        SecuritySPI.Assessment(
            create: { _, _, _, _ in nil }, copyResult: real.copyResult, operationKey: real.operationKey,
            operationExecute: real.operationExecute, verdictKey: real.verdictKey, authorityKey: real.authorityKey,
            sourceKey: real.sourceKey, originatorKey: real.originatorKey,
            codeSigningErrorKey: real.codeSigningErrorKey)
    }

    static func assess(_ app: URL, route: AssessmentRoute, timeout: Duration = Verifier.defaultAssessmentTimeout)
        async -> AssessmentResult
    {
        await Verifier.$assessmentRoute.withValue(route) { await Verifier.assess(app: app, timeout: timeout) }
    }

    static func both(_ app: URL) async throws -> (framework: Assessment, spctl: Assessment) {
        let framework = try #require(await assess(app, route: .frameworkOnly).assessment)
        let spctl = try #require(await assess(app, route: .spctlOnly).assessment)
        #expect(framework.method == .securityFramework)
        #expect(spctl.method == .spctl)
        return (framework, spctl)
    }

    @Test(arguments: Fixtures.notarized + [Fixtures.developmentSigned])
    func realAppsMatchFramework(name: String) async throws {
        let (framework, spctl) = try await Self.both(try Fixtures.real(name))
        #expect(spctl.accepted == framework.accepted)
        #expect(spctl.source == framework.source)
        #expect(spctl.status == framework.status)
    }

    @Test(arguments: ["AdHoc", "Unsigned", "Tampered"])
    func syntheticAppsMatchFramework(name: String) async throws {
        let (framework, spctl) = try await Self.both(try Fixtures.synthetic(name))
        #expect(!spctl.accepted)
        #expect(spctl.source == framework.source)
        #expect(spctl.status == framework.status)
    }

    @Test func syntheticDetails() async throws {
        let unsigned = try #require(await Self.assess(try Fixtures.synthetic("Unsigned"), route: .spctlOnly).assessment)
        #expect(unsigned.source == Assessment.Source.noUsableSignature)
        let tampered = try #require(await Self.assess(try Fixtures.synthetic("Tampered"), route: .spctlOnly).assessment)
        #expect(tampered.status == errSecCSBadResource)
    }

    @Test func brokenFrameworkFallsBack() async throws {
        let spi = try #require(Self.brokenSPI)
        let route = AssessmentRoute(spi: spi, spctl: AssessmentRoute.systemSpctl)
        let assessment = try #require(await Self.assess(try Fixtures.real("Rectangle"), route: route).assessment)
        #expect(assessment.method == .spctl)
        #expect(assessment.isCheckedByApple)
        #expect(
            await Self.assess(try Fixtures.real("Rectangle"), route: AssessmentRoute(spi: spi, spctl: nil))
                == .unavailable)
    }

    @Test(arguments: Fixtures.notarized)
    func verdictInstallsWithoutFramework(name: String) async throws {
        let app = try Fixtures.real(name)
        let verdict = await Verifier.$assessmentRoute.withValue(.spctlOnly) { await Verifier.verdict(app: app) }
        #expect(verdict.decision == .install)
        #expect(verdict.allowsPreApproval)
        #expect(verdict.assessment?.assessment?.method == .spctl)
    }

    @Test func syncOverloadUsesRoute() throws {
        let app = try Fixtures.real("Stats")
        let result = Verifier.$assessmentRoute.withValue(.spctlOnly) { Verifier.assess(app: app) }
        #expect(result.assessment?.method == .spctl)
        #expect(result.assessment?.isCheckedByApple == true)
    }

    @Test func missingToolIsUnavailable() async throws {
        let route = AssessmentRoute(spi: nil, spctl: Fixtures.root.appending(path: "no-such-spctl"))
        #expect(await Self.assess(try Fixtures.real("Rectangle"), route: route) == .unavailable)
    }

    /// A stand-in spctl that records its PID and hangs, like one stuck on a ticket lookup.
    static func hangingTool() throws -> (tool: URL, pidFile: URL, folder: URL) {
        let folder = Fixtures.root.appending(path: "work/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pidFile = folder.appending(path: "pid")
        let tool = folder.appending(path: "hang")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 60\n".write(
            to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, pidFile, folder)
    }

    /// Long enough for the stand-in to start and write its PID under a parallel test run,
    /// far short of its 60 s sleep.
    static let hangTimeout: Duration = .seconds(3)

    /// Waits up to `limit` for `pid` to be gone (exited and reaped).
    static func gone(_ pid: pid_t, within limit: Duration = .seconds(5)) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    static func pid(_ file: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test func timeoutKillsChild() async throws {
        let (tool, pidFile, folder) = try Self.hangingTool()
        defer { try? FileManager.default.removeItem(at: folder) }
        let route = AssessmentRoute(spi: nil, spctl: tool)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await Self.assess(try Fixtures.real("Rectangle"), route: route, timeout: Self.hangTimeout)
        #expect(result == .notAssessed(.timedOut))
        #expect(clock.now - start < Self.hangTimeout + .seconds(2))
        #expect(try await Self.gone(try await Self.pid(pidFile)))
    }

    @Test func syncTimeoutKillsChild() async throws {
        let (tool, pidFile, folder) = try Self.hangingTool()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try Fixtures.real("Rectangle")
        let route = AssessmentRoute(spi: nil, spctl: tool)
        let result = await Task.detached {
            Verifier.$assessmentRoute.withValue(route) { Verifier.assess(app: app, timeout: Self.hangTimeout) }
        }.value
        #expect(result == .notAssessed(.timedOut))
        #expect(try await Self.gone(try await Self.pid(pidFile)))
    }

    @Test func cancellationKillsChild() async throws {
        let (tool, pidFile, folder) = try Self.hangingTool()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try Fixtures.real("Rectangle")
        let task = Task { await Self.assess(app, route: AssessmentRoute(spi: nil, spctl: tool)) }
        let pid = try await Self.pid(pidFile)
        task.cancel()
        #expect(await task.value == .notAssessed(.cancelled))
        #expect(try await Self.gone(pid))
    }

    @Test func parsesOutput() {
        let path = "/x/A: B.app"
        let accepted = Spctl.parse("\(path): accepted\nsource=Notarized Developer ID\n", path: path, exitStatus: 0)
        #expect(accepted == Assessment(accepted: true, source: "Notarized Developer ID", status: nil, method: .spctl))
        let reason = SecCopyErrorMessageString(errSecCSRevokedNotarization, nil)! as String
        let revoked = Spctl.parse(
            "\(path): rejected (\(reason))\nsource=Notarized Developer ID\n", path: path, exitStatus: 3)
        #expect(revoked?.isRevoked == true)
        #expect(revoked?.accepted == false)
        #expect(Spctl.parse("\(path): rejected\n", path: path, exitStatus: 3)?.source == nil)
        #expect(Spctl.parse("\(path): something new\n", path: path, exitStatus: 1) == nil)
        #expect(Spctl.parse("\(path): accepted\n", path: path, exitStatus: 3) == nil)
        #expect(Spctl.parse("spctl: usage\n", path: path, exitStatus: 2) == nil)
    }
}
