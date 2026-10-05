import Foundation
import Testing
@testable import Squatter

@MainActor
struct PortListModelTests {
    private func makeModel(
        runner: FakeRunner = FakeRunner(.success(lsofResult(sampleLsof))),
        kills: KillRecorder = KillRecorder(names: [42: "node"]),
        actions: RecordingActions = RecordingActions(),
        defaults: UserDefaults = freshDefaults(),
        badgeInterval: Duration = .milliseconds(100),
        minimumRefreshDisplay: Duration = .zero
    ) -> PortListModel {
        PortListModel(
            scanner: PortScanner(runner: runner, currentUID: 501, userName: testUserName, docker: nil),
            killer: kills.killer,
            actions: actions,
            preferences: Preferences(defaults: defaults),
            forceKillGrace: .milliseconds(60),
            forceKillWait: .milliseconds(60),
            badgeInterval: badgeInterval,
            minimumRefreshDisplay: minimumRefreshDisplay
        )
    }

    /// A loaded model with one row Squatter mapped to a Docker container (`api-db-1` on
    /// 5432, from the plan 007 fixture), for the Stop Container tests below.
    private func makeContainerModel(
        stop: StopRecorder = StopRecorder(),
        kills: KillRecorder = KillRecorder(names: [600: "com.docker.backend", 42: "node"]),
        lsof: String = "p600\nccom.docker.backend\nu501\nf1\nPTCP\nn*:5432\nTST=LISTEN\n"
    ) async throws -> PortListModel {
        let url = try #require(Bundle(for: Anchor.self).url(forResource: "docker-ps-sample", withExtension: "txt"))
        let dockerFixture = try String(contentsOf: url, encoding: .utf8)
        let docker = DockerProbe(runner: FakeRunner(.success(lsofResult(dockerFixture))), executablePath: "/test/docker")
        await docker.refreshNow()
        let scanner = PortScanner(runner: FakeRunner(.success(lsofResult(lsof))), currentUID: 501, userName: testUserName, docker: docker)
        let model = PortListModel(
            scanner: scanner,
            killer: kills.killer,
            stopper: stop.stopper,
            actions: RecordingActions(),
            preferences: Preferences(defaults: freshDefaults()),
            forceKillGrace: .milliseconds(60),
            forceKillWait: .milliseconds(60),
            badgeInterval: .milliseconds(100)
        )
        await model.refresh()
        return model
    }

    @Test func refreshLoadsListeners() async {
        let model = makeModel()
        #expect(!model.hasLoaded)
        await model.refresh()
        #expect(model.hasLoaded)
        #expect(model.listeners == [sampleListener])
        #expect(model.lastError == nil)
    }

    @Test func failedRefreshKeepsLastListAndReportsError() async {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let model = makeModel(runner: runner)
        await model.refresh()
        await runner.set(.failure(.launchFailed("boom")))
        await model.refresh()
        #expect(model.listeners == [sampleListener])
        #expect(model.lastError?.contains("boom") == true)
        await runner.set(.success(lsofResult("")))
        await model.refresh()
        #expect(model.listeners.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test func filterMatchesPortNameAndPid() async {
        let two = sampleLsof + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"
        let model = makeModel(runner: FakeRunner(.success(lsofResult(two))))
        await model.refresh()
        #expect(model.filtered.count == 2)
        model.filterText = "NODE"
        #expect(model.filtered.map(\.processName) == ["node"])
        model.filterText = "543"
        #expect(model.filtered.map(\.port) == [5432])
        model.filterText = "7"
        #expect(model.filtered.map(\.pid) == [7])
        model.filterText = "nothing"
        #expect(model.filtered.isEmpty)
    }

    @Test func killThatExitsRemovesRowAndState() async {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let kills = KillRecorder(names: [42: "node"])
        kills.onSignal { pid, _ in kills.setName(nil, for: pid) }
        let model = makeModel(runner: runner, kills: kills)
        await model.refresh()
        await runner.set(.success(lsofResult("")))

        await model.kill(sampleListener)

        #expect(kills.signals.map(\.1) == [SIGTERM])
        #expect(model.listeners.isEmpty)
        #expect(model.killStates.isEmpty)
    }

    @Test func stubbornProcessOffersForceKillThenDies() async {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let kills = KillRecorder(names: [42: "node"])
        kills.onSignal { pid, sig in if sig == SIGKILL { kills.setName(nil, for: pid) } }
        let model = makeModel(runner: runner, kills: kills)
        await model.refresh()

        await model.kill(sampleListener)
        #expect(model.killState(for: sampleListener) == .stillRunning)
        #expect(model.listeners == [sampleListener])

        await runner.set(.success(lsofResult("")))
        await model.forceKill(sampleListener)
        #expect(kills.signals.map(\.1) == [SIGTERM, SIGKILL])
        #expect(model.killStates.isEmpty)
        #expect(model.listeners.isEmpty)
    }

    @Test func killErrorIsSurfacedAndDismissable() async {
        let kills = KillRecorder(names: [42: "node"], signalResult: EPERM)
        let model = makeModel(kills: kills)
        await model.refresh()
        await model.kill(sampleListener)
        guard case .failed(let message)? = model.killState(for: sampleListener) else {
            Issue.record("expected .failed, got \(String(describing: model.killState(for: sampleListener)))")
            return
        }
        #expect(message.contains("another user"))
        model.dismissKillError(for: sampleListener)
        #expect(model.killState(for: sampleListener) == nil)
    }

    @Test func pollingRefreshesOnIntervalAndStops() async throws {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let defaults = freshDefaults()
        Preferences(defaults: defaults).refreshInterval = 0.5 // clamp floor; fast enough for a test
        let model = makeModel(runner: runner, defaults: defaults)

        model.startPolling()
        model.startPolling() // idempotent
        #expect(model.isPolling)
        try await Task.sleep(for: .milliseconds(1200))
        model.stopPolling()
        #expect(!model.isPolling)
        let launches = await runner.launches
        #expect(launches >= 2 && launches <= 4, "got \(launches)")

        try await Task.sleep(for: .milliseconds(700))
        #expect(await runner.launches == launches, "must not scan after stopPolling")
    }

    /// The footer's refresh icon swaps for a spinner while `isRefreshing` is true. A poll every
    /// two seconds made it strobe, so only a scan the user asked for may set it — while the list
    /// itself still has to keep updating on the poll.
    @Test func backgroundPollingUpdatesTheListWithoutFlashingTheRefreshIndicator() async throws {
        final class Flag: @unchecked Sendable { var didFire = false }
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let defaults = freshDefaults()
        Preferences(defaults: defaults).refreshInterval = 0.5 // clamp floor; fast enough for a test
        let model = makeModel(runner: runner, defaults: defaults)

        // Fires on the first change to anything read in the first closure, then stops tracking —
        // "did `isRefreshing` ever move", which is exactly what the eye sees as a flicker.
        let flag = Flag()
        withObservationTracking { _ = model.isRefreshing } onChange: { flag.didFire = true }

        model.startPolling()
        try await Task.sleep(for: .milliseconds(1200))
        model.stopPolling()

        #expect(await runner.launches >= 2, "the poll must keep scanning")
        #expect(model.listeners == [sampleListener], "the list must still be up to date")
        #expect(!flag.didFire, "a background poll must not touch isRefreshing")

        await model.refresh()
        #expect(flag.didFire, "a refresh the user asked for must show progress")
    }

    /// The footer's arrow rotates while `isRefreshing`, so a scan that returns in 80 ms would
    /// stop it a fraction of a turn in. The hold keeps the indicator up long enough to read as a
    /// refresh — but it must not hold the *list* back, which is the half that would be a
    /// regression: the rows and counts are already current before the arrow stops.
    @Test func aFastRefreshStillShowsTheIndicatorLongEnoughToSeeIt() async throws {
        let model = makeModel(minimumRefreshDisplay: .milliseconds(300))
        let refresh = Task { await model.refresh() }

        try await Task.sleep(for: .milliseconds(120)) // well past a fake scan, well short of the hold
        #expect(model.isRefreshing, "the indicator holds after a scan that returned instantly")
        #expect(model.listeners == [sampleListener], "the list is current *during* the hold, not after it")

        await refresh.value
        #expect(!model.isRefreshing, "and it clears once the hold is over")
    }

    /// A background poll never sets `isRefreshing`, so it must never pay the hold either —
    /// otherwise a hold longer than the poll interval would throttle the list to the indicator's
    /// pace for an indicator nobody is showing.
    @Test func aBackgroundPollDoesNotPayTheIndicatorHold() async throws {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let defaults = freshDefaults()
        Preferences(defaults: defaults).refreshInterval = 0.5
        // Far longer than the window below: if the poll waited on this, it would scan once at most.
        let model = makeModel(runner: runner, defaults: defaults, minimumRefreshDisplay: .seconds(30))

        model.startPolling()
        try await Task.sleep(for: .milliseconds(1200))
        model.stopPolling()

        #expect(await runner.launches >= 2, "the poll must keep its own cadence")
        #expect(!model.isRefreshing)
    }

    @Test func selectionClearsWhenRowDisappears() async {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let model = makeModel(runner: runner)
        await model.refresh()
        model.selection = sampleListener.id
        await runner.set(.success(lsofResult("")))
        await model.refresh()
        #expect(model.selection == nil)
    }

    // MARK: ignore list

    private static let twoLsof = sampleLsof + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"

    @Test func ignoringAPortHidesItAndCountsIt() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.twoLsof))))
        await model.refresh()
        model.selection = sampleListener.id
        model.ignorePort(of: sampleListener)
        #expect(model.filtered.map(\.port) == [5432])
        #expect(model.hiddenCount == 1)
        #expect(model.isIgnored(sampleListener))
        #expect(model.selection == nil, "hidden row can't stay selected")
        model.showIgnored = true
        #expect(model.filtered.map(\.port) == [3000, 5432])
        #expect(model.hiddenCount == 1, "count is independent of reveal")
    }

    @Test func ignoringAProcessHidesEveryPortItOwns() async {
        let sameProcess = sampleLsof + "p42\ncnode\nu501\nf2\nPTCP\nn*:3001\nTST=LISTEN\n"
        let model = makeModel(runner: FakeRunner(.success(lsofResult(sameProcess))))
        await model.refresh()
        #expect(model.listeners.count == 2)
        model.ignoreProcess(of: sampleListener)
        #expect(model.filtered.isEmpty)
        #expect(model.hiddenCount == 2)
        model.unignore(sampleListener)
        #expect(model.filtered.count == 2)
        #expect(model.hiddenCount == 0)
    }

    @Test func ignoreListPersistsAcrossModels() async {
        let defaults = freshDefaults()
        let first = makeModel(defaults: defaults)
        await first.refresh()
        first.ignorePort(of: sampleListener)
        first.ignoreProcess(of: sampleListener)

        let second = makeModel(defaults: defaults)
        await second.refresh()
        #expect(second.ignoredPorts == [3000])
        #expect(second.ignoredProcessNames == ["node"])
        #expect(second.filtered.isEmpty)

        second.removeIgnoredPort(3000)
        #expect(second.filtered.isEmpty, "process rule still hides it")
        second.removeIgnoredProcessName("node")
        #expect(second.filtered == [sampleListener])
        #expect(Preferences(defaults: defaults).ignoredPorts.isEmpty)
        #expect(Preferences(defaults: defaults).ignoredProcessNames.isEmpty)
    }

    // MARK: typed ignore list

    @Test func typedPortsAreAddedAndNormalised() async {
        let model = makeModel()
        let result = model.addIgnoredPorts(from: "3000, 5173\n8080 9090")
        #expect(result.added == [3000, 5173, 8080, 9090])
        #expect(result.skipped == [])
        #expect(model.ignoredPorts == [3000, 5173, 8080, 9090])
    }

    @Test func invalidTokensAreReportedNotSwallowed() async {
        let model = makeModel()
        let result = model.addIgnoredPorts(from: "3000, abc, 99999, 0, -1, 3000.5")
        #expect(result.added == [3000])
        #expect(result.skipped == ["abc", "99999", "0", "-1", "3000.5"])
    }

    @Test func emptyInputChangesNothing() async {
        let model = makeModel()
        let before = model.ignoredPorts
        let result = model.addIgnoredPorts(from: "   ,,\n ")
        #expect(result.added.isEmpty)
        #expect(result.skipped.isEmpty)
        #expect(model.ignoredPorts == before)
    }

    @Test func typedPortsHideMatchingRowsImmediately() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.twoLsof))))
        await model.refresh()
        model.addIgnoredPorts(from: "3000")
        #expect(model.filtered.map(\.port) == [5432])
        #expect(model.hiddenCount == 1)
    }

    @Test func typedPortsPersistAcrossModels() async {
        let defaults = freshDefaults()
        let first = makeModel(defaults: defaults)
        first.addIgnoredPorts(from: "3000, 5173")

        let second = makeModel(defaults: defaults)
        #expect(second.ignoredPorts == [3000, 5173])
    }

    @Test func addingASelectedPortClearsTheSelection() async {
        let model = makeModel()
        await model.refresh()
        model.selection = sampleListener.id
        model.addIgnoredPorts(from: "3000")
        #expect(model.selection == nil)
    }

    @Test func duplicatesAreIdempotent() async {
        let model = makeModel()
        _ = model.addIgnoredPorts(from: "3000")
        let second = model.addIgnoredPorts(from: "3000")
        #expect(model.ignoredPorts.count == 1)
        #expect(second.added == [3000])
    }

    @Test func textFilterAndIgnoreCompose() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.twoLsof))))
        await model.refresh()
        model.ignorePort(of: sampleListener)
        model.filterText = "node"
        #expect(model.filtered.isEmpty)
        model.showIgnored = true
        #expect(model.filtered.map(\.processName) == ["node"])
    }

    // MARK: high port threshold

    private static let highPortLsof = sampleLsof + "p9\ncmDNSResponder\nu501\nf1\nPTCP\nn*:52398\nTST=LISTEN\n"

    @Test func hideHighPortsIsOffByDefault() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))))
        await model.refresh()
        #expect(!model.hideHighPorts)
        #expect(model.filtered.map(\.port).sorted() == [3000, 52398])
        #expect(model.hiddenCount == 0)
    }

    @Test func thresholdHidesPortsStrictlyAbove() async {
        let lsof = sampleLsof
            + "p10\ncdaemon\nu501\nf1\nPTCP\nn*:10000\nTST=LISTEN\n"
            + "p11\ncdaemon\nu501\nf1\nPTCP\nn*:10001\nTST=LISTEN\n"
        let model = makeModel(runner: FakeRunner(.success(lsofResult(lsof))))
        await model.refresh()
        model.hideHighPorts = true
        model.highPortThreshold = 10_000
        let visiblePorts = model.filtered.map(\.port)
        #expect(visiblePorts.contains(10000), "10000 is not above the threshold")
        #expect(!visiblePorts.contains(10001), "10001 is above the threshold")
    }

    @Test func hiddenHighPortsAreCountedAndRevealable() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))))
        await model.refresh()
        model.hideHighPorts = true
        #expect(model.hiddenCount == 1)
        #expect(model.filtered.map(\.port) == [3000])
        model.showIgnored = true
        let ignored = model.groups.first { $0.kind == .ignored }
        #expect(ignored?.listeners.map(\.port) == [52398])
    }

    @Test func explicitIgnoreOutranksTheThreshold() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))))
        await model.refresh()
        model.hideHighPorts = true
        let highListener = model.listeners.first { $0.port == 52398 }!
        model.ignorePort(of: highListener)
        #expect(model.ignoreReason(highListener) == .port, "an explicit list entry outranks the rule")
    }

    @Test func stopHidingHighPortsRevealsEverything() async {
        let defaults = freshDefaults()
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))), defaults: defaults)
        await model.refresh()
        model.hideHighPorts = true
        #expect(model.hiddenCount == 1)
        model.stopHidingHighPorts()
        #expect(model.hiddenCount == 0)
        #expect(Preferences(defaults: defaults).hideHighPorts == false)
    }

    @Test func thresholdPersistsAcrossModels() async {
        let defaults = freshDefaults()
        let first = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))), defaults: defaults)
        await first.refresh()
        first.hideHighPorts = true
        first.highPortThreshold = 40_000

        let second = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))), defaults: defaults)
        await second.refresh()
        #expect(second.hideHighPorts)
        #expect(second.highPortThreshold == 40_000)
        #expect(second.filtered.map(\.port) == first.filtered.map(\.port))
    }

    @Test func selectionClearsWhenTheThresholdHidesIt() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))))
        await model.refresh()
        let highListener = model.listeners.first { $0.port == 52398 }!
        model.selection = highListener.id
        model.hideHighPorts = true
        #expect(model.selection == nil)
    }

    @Test func menuBarCountExcludesHighPorts() async {
        let model = makeModel(runner: FakeRunner(.success(lsofResult(Self.highPortLsof))))
        await model.refresh()
        model.hideHighPorts = true
        model.showCountInMenuBar = true
        #expect(model.menuBarCount == 1)
    }

    // MARK: sort

    @Test func sortByProcessNameIsCaseInsensitiveThenPort() async {
        let lsof = "p1\ncZeta\nu501\nf1\nPTCP\nn*:80\nTST=LISTEN\n"
            + "p2\ncalpha\nu501\nf1\nPTCP\nn*:9000\nTST=LISTEN\n"
            + "p3\ncBeta\nu501\nf1\nPTCP\nn*:443\nTST=LISTEN\n"
            + "p4\ncalpha\nu501\nf1\nPTCP\nn*:8000\nTST=LISTEN\n"
        let defaults = freshDefaults()
        let model = makeModel(runner: FakeRunner(.success(lsofResult(lsof))), defaults: defaults)
        await model.refresh()
        #expect(model.sortOrder == .port)
        #expect(model.filtered.map(\.port) == [80, 443, 8000, 9000])

        model.sortOrder = .processName
        #expect(model.filtered.map { "\($0.processName):\($0.port)" } == ["alpha:8000", "alpha:9000", "Beta:443", "Zeta:80"])
        #expect(Preferences(defaults: defaults).sortOrder == .processName, "persisted")
        #expect(makeModel(defaults: defaults).sortOrder == .processName, "restored on next launch")
    }

    /// PID order is roughly launch order, which is the question "which of these did I just
    /// start" — hence the tie-break on port rather than on name: one process holding several
    /// ports must not come out in scan order inside its own PID.
    @Test func sortByPIDIsAscendingThenPort() async {
        let lsof = "p900\ncnode\nu501\nf1\nPTCP\nn*:3000\nTST=LISTEN\n"
            + "p12\ncpostgres\nu501\nf1\nPTCP\nn*:5432\nTST=LISTEN\n"
            + "p900\ncnode\nu501\nf2\nPTCP\nn*:24678\nTST=LISTEN\n"
            + "p120\nccaddy\nu501\nf1\nPTCP\nn*:443\nTST=LISTEN\n"
        let defaults = freshDefaults()
        let model = makeModel(runner: FakeRunner(.success(lsofResult(lsof))), defaults: defaults)
        await model.refresh()

        model.sortOrder = .pid
        // 12 before 120 before 900: numeric, not the string order the row's "PID 87489" might suggest.
        #expect(model.filtered.map { "\($0.pid):\($0.port)" } == ["12:5432", "120:443", "900:3000", "900:24678"])
        #expect(Preferences(defaults: defaults).sortOrder == .pid, "persisted")
        #expect(makeModel(defaults: defaults).sortOrder == .pid, "restored on next launch")
    }

    @Test func groupsSplitYoursOthersAndIgnored() async {
        let lsof = "p1\nclaunchd\nu0\nf1\nPTCP\nn*:22\nTST=LISTEN\n" + sampleLsof
            + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"
        let model = makeModel(runner: FakeRunner(.success(lsofResult(lsof))))
        await model.refresh()
        #expect(model.groups.map(\.kind) == [.yours, .otherUsers])
        #expect(model.groups[0].listeners.map(\.port) == [3000, 5432])
        #expect(model.groups[1].listeners.map(\.port) == [22])

        model.ignorePort(of: sampleListener)
        #expect(model.groups.map(\.kind) == [.yours, .otherUsers])
        model.showIgnored = true
        #expect(model.groups.map(\.kind) == [.yours, .otherUsers, .ignored])
        #expect(model.groups[2].listeners.map(\.port) == [3000])
        model.filterText = "launchd"
        #expect(model.groups.map(\.kind) == [.otherUsers], "empty groups drop out")
    }

    // MARK: keyboard intents

    @Test func keyboardIntentsActOnTheVisibleSelection() async throws {
        let actions = RecordingActions()
        let kills = KillRecorder(names: [42: "node"])
        kills.onSignal { pid, _ in kills.setName(nil, for: pid) }
        let model = makeModel(kills: kills, actions: actions)
        await model.refresh()

        #expect(!model.openSelected())
        #expect(!model.copySelectedURL())
        #expect(!model.killSelected())

        model.selection = sampleListener.id
        #expect(model.openSelected())
        #expect(model.copySelectedURL())
        #expect(actions.opened.count == 1 && actions.copied == ["http://localhost:3000"])

        model.filterText = "zzz" // selection no longer visible
        #expect(model.selectedListener == nil)
        #expect(!model.openSelected())
        model.filterText = ""

        #expect(model.killSelected(), "arms the confirmation")
        #expect(model.killState(for: sampleListener) == .confirming)
        #expect(kills.signals.isEmpty, "nothing is signalled until confirmed")
        await model.kill(sampleListener)
        #expect(kills.signals.map(\.1) == [SIGTERM])
    }

    // MARK: kill confirmation

    @Test func killPathsArmAConfirmationInsteadOfSignalling() async {
        let kills = KillRecorder(names: [42: "node"])
        let model = makeModel(kills: kills)
        await model.refresh()

        model.requestKill(sampleListener)
        #expect(model.killState(for: sampleListener) == .confirming)
        #expect(model.isAwaitingKillConfirmation)
        #expect(kills.signals.isEmpty)

        model.requestKill(sampleListener) // idempotent while armed
        #expect(model.killState(for: sampleListener) == .confirming)

        model.cancelKill(sampleListener)
        #expect(model.killState(for: sampleListener) == nil)
        #expect(!model.isAwaitingKillConfirmation)
        #expect(kills.signals.isEmpty)
    }

    @Test func confirmingSendsSigtermAndEscapeCancelsEverything() async {
        let two = sampleLsof + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"
        let kills = KillRecorder(names: [42: "node", 7: "postgres"])
        kills.onSignal { pid, _ in kills.setName(nil, for: pid) }
        let model = makeModel(runner: FakeRunner(.success(lsofResult(two))), kills: kills)
        await model.refresh()

        model.requestKill(sampleListener)
        model.requestKill(model.listeners[1])
        #expect(model.isAwaitingKillConfirmation)
        model.cancelAllKillConfirmations()
        #expect(!model.isAwaitingKillConfirmation)
        #expect(kills.signals.isEmpty)

        model.requestKill(sampleListener)
        await model.kill(sampleListener)
        #expect(kills.signals.map(\.1) == [SIGTERM])
        #expect(model.killState(for: sampleListener) == nil)
    }

    @Test func armingASecondRowCancelsTheFirst() async {
        let two = sampleLsof + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"
        let kills = KillRecorder(names: [42: "node", 7: "postgres"])
        let model = makeModel(runner: FakeRunner(.success(lsofResult(two))), kills: kills)
        await model.refresh()
        let postgres = model.listeners[1]

        model.requestKill(sampleListener)
        model.requestKill(postgres)
        #expect(model.killState(for: sampleListener) == nil, "the first row disarms")
        #expect(model.killState(for: postgres) == .confirming)
        #expect(model.killStates.values.count(where: { $0 == .confirming }) == 1)
        #expect(kills.signals.isEmpty)
    }

    @Test func armingDoesNotDisturbAKillAlreadyInFlight() async {
        let two = sampleLsof + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"
        let kills = KillRecorder(names: [42: "node", 7: "postgres"])
        let model = makeModel(runner: FakeRunner(.success(lsofResult(two))), kills: kills)
        await model.refresh()
        let postgres = model.listeners[1]

        await model.kill(sampleListener) // node never exits → .stillRunning
        #expect(model.killState(for: sampleListener) == .stillRunning)
        model.requestKill(postgres)
        #expect(model.killState(for: sampleListener) == .stillRunning, "in-flight kills survive")
        #expect(model.killState(for: postgres) == .confirming)
    }

    // MARK: Stop Container

    @Test func stopContainerArmsAConfirmationInsteadOfRunningDocker() async throws {
        let stop = StopRecorder()
        let model = try await makeContainerModel(stop: stop)
        let container = try #require(model.listeners.first { $0.container != nil })

        model.requestStopContainer(container)
        #expect(model.killState(for: container) == .confirmingStop)
        #expect(model.isAwaitingKillConfirmation)
        #expect(stop.launches.isEmpty)
    }

    @Test func confirmedStopRunsDockerStopOnceAndRefreshes() async throws {
        let stop = StopRecorder()
        let model = try await makeContainerModel(stop: stop)
        let container = try #require(model.listeners.first { $0.container != nil })
        let containerID = try #require(container.container?.id)

        model.requestStopContainer(container)
        await model.stopContainer(container)

        #expect(stop.launches == [containerID])
        #expect(model.killState(for: container) == nil)
    }

    @Test func containerRowsCannotArmAProcessKill() async throws {
        let kills = KillRecorder(names: [600: "com.docker.backend"])
        let model = try await makeContainerModel(kills: kills)
        let container = try #require(model.listeners.first { $0.container != nil })

        model.requestKill(container)
        #expect(model.killState(for: container) == nil)
        model.requestForceKill(container)
        #expect(model.killState(for: container) == nil)
        #expect(kills.signals.isEmpty)
    }

    @Test func nonContainerRowsCannotArmAStop() async {
        let model = makeModel()
        await model.refresh()
        model.requestStopContainer(sampleListener)
        #expect(model.killState(for: sampleListener) == nil)
    }

    @Test func escapeCancelsAnArmedStop() async throws {
        let stop = StopRecorder(delay: .milliseconds(150))
        let model = try await makeContainerModel(stop: stop)
        let container = try #require(model.listeners.first { $0.container != nil })

        model.requestStopContainer(container)
        #expect(model.killState(for: container) == .confirmingStop)

        let inFlight = Task { await model.stopContainer(container) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.killState(for: container) == .stopping)

        model.cancelAllKillConfirmations()
        #expect(model.killState(for: container) == .stopping, "an in-flight stop survives cancellation")

        await inFlight.value
        #expect(model.killState(for: container) == nil)
    }

    @Test func stopFailureSurfacesTheMessageAndIsDismissable() async throws {
        let stop = StopRecorder(result: .success(CommandResult(
            stdout: Data(),
            stderr: Data("Error response from daemon: No such container".utf8),
            exitCode: 1
        )))
        let model = try await makeContainerModel(stop: stop)
        let container = try #require(model.listeners.first { $0.container != nil })

        await model.stopContainer(container)
        guard case .failed(let message)? = model.killState(for: container) else {
            Issue.record("expected .failed, got \(String(describing: model.killState(for: container)))")
            return
        }
        #expect(message.contains("No such container"))
        model.dismissKillError(for: container)
        #expect(model.killState(for: container) == nil)
    }

    @Test func deleteKeyArmsStopOnAContainerRow() async throws {
        let model = try await makeContainerModel()
        let container = try #require(model.listeners.first { $0.container != nil })
        model.selection = container.id

        #expect(model.killSelected())
        #expect(model.killState(for: container) == .confirmingStop)
    }

    @Test func confirmationIsRefusedForOtherUsersRows() async {
        let root = "p1\nclaunchd\nu0\nf1\nPTCP\nn*:22\nTST=LISTEN\n"
        let model = makeModel(runner: FakeRunner(.success(lsofResult(root))), kills: KillRecorder(names: [1: "launchd"]))
        await model.refresh()
        let launchd = model.listeners[0]
        model.requestKill(launchd)
        #expect(model.killState(for: launchd) == nil)
        #expect(!model.isAwaitingKillConfirmation)
    }

    @Test func forceKillFromTheMenuArmsAConfirmationInsteadOfSignalling() async {
        let kills = KillRecorder(names: [42: "node"])
        let model = makeModel(kills: kills)
        await model.refresh()

        model.requestForceKill(sampleListener)
        #expect(model.killState(for: sampleListener) == .confirmingForce)
        #expect(model.isAwaitingKillConfirmation)
        #expect(kills.signals.isEmpty)

        model.cancelKill(sampleListener)
        #expect(model.killState(for: sampleListener) == nil)
        #expect(kills.signals.isEmpty)
    }

    @Test func confirmedForceKillSendsSigkillAndNothingElse() async {
        let kills = KillRecorder(names: [42: "node"])
        kills.onSignal { pid, _ in kills.setName(nil, for: pid) }
        let model = makeModel(kills: kills)
        await model.refresh()

        model.requestForceKill(sampleListener)
        await model.forceKill(sampleListener)
        #expect(kills.signals.map(\.1) == [SIGKILL])
        #expect(model.killState(for: sampleListener) == nil)
    }

    @Test func forceKillConfirmationIsRefusedForOtherUsersRows() async {
        let root = "p1\nclaunchd\nu0\nf1\nPTCP\nn*:22\nTST=LISTEN\n"
        let model = makeModel(runner: FakeRunner(.success(lsofResult(root))), kills: KillRecorder(names: [1: "launchd"]))
        await model.refresh()
        let launchd = model.listeners[0]
        model.requestForceKill(launchd)
        #expect(model.killState(for: launchd) == nil)
        #expect(!model.isAwaitingKillConfirmation)
    }

    @Test func theModelRefusesToSignalOtherUsersProcesses() async {
        let root = "p1\nclaunchd\nu0\nf1\nPTCP\nn*:22\nTST=LISTEN\n"
        let kills = KillRecorder(names: [1: "launchd"])
        let model = makeModel(runner: FakeRunner(.success(lsofResult(root))), kills: kills)
        await model.refresh()
        let launchd = model.listeners[0]

        await model.kill(launchd)
        await model.forceKill(launchd)
        #expect(kills.signals.isEmpty)
        #expect(model.killStates.isEmpty)
    }

    @Test func closingThePopoverClearsArmedPromptsButNotKillsInFlight() async {
        let two = sampleLsof + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"
        let kills = KillRecorder(names: [42: "node", 7: "postgres"])
        let model = makeModel(runner: FakeRunner(.success(lsofResult(two))), kills: kills)
        await model.refresh()
        let postgres = model.listeners[1]

        await model.kill(sampleListener) // node never exits → .stillRunning
        #expect(model.killState(for: sampleListener) == .stillRunning)
        model.requestForceKill(postgres)

        model.stopPolling()
        #expect(model.killState(for: sampleListener) == .stillRunning)
        #expect(model.killState(for: postgres) == nil)
        #expect(!model.isAwaitingKillConfirmation)
    }

    @Test func armedConfirmationClearsWhenTheRowDisappears() async {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let model = makeModel(runner: runner)
        await model.refresh()
        model.requestKill(sampleListener)
        #expect(model.isAwaitingKillConfirmation)
        await runner.set(.success(lsofResult("")))
        await model.refresh()
        #expect(model.killStates.isEmpty)
        #expect(!model.isAwaitingKillConfirmation)
    }

    @Test func killSelectedRefusesOtherUsersRowsAndDoubleKills() async {
        let root = "p1\nclaunchd\nu0\nf1\nPTCP\nn*:22\nTST=LISTEN\n" + sampleLsof
        let kills = KillRecorder(names: [1: "launchd", 42: "node"])
        let model = makeModel(runner: FakeRunner(.success(lsofResult(root))), kills: kills)
        await model.refresh()

        model.selection = "1:22"
        #expect(!model.killSelected(), "not our process")

        model.selection = sampleListener.id
        model.requestKill(sampleListener)
        await model.kill(sampleListener) // stays .stillRunning (name never changes)
        #expect(model.killState(for: sampleListener) == .stillRunning)
        #expect(!model.killSelected(), "kill already in flight")
        #expect(kills.signals.count == 1)
    }

    // MARK: menu bar count badge

    @Test func badgeOffMeansNoCountAndNoBackgroundPolling() async throws {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let model = makeModel(runner: runner)
        #expect(model.menuBarCount == nil)
        #expect(!model.isPolling)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await runner.launches == 0)
        await model.refresh()
        #expect(model.menuBarCount == nil, "still nil while the badge is off")
    }

    @Test func badgeOnPollsInBackgroundAndCountsVisibleRows() async throws {
        let two = sampleLsof + "p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"
        let runner = FakeRunner(.success(lsofResult(two)))
        let defaults = freshDefaults()
        let model = makeModel(runner: runner, defaults: defaults)

        model.showCountInMenuBar = true
        #expect(model.isPolling)
        try await Task.sleep(for: .milliseconds(350))
        let launches = await runner.launches
        #expect(launches >= 2 && launches <= 5, "background cadence, got \(launches)")
        #expect(model.menuBarCount == 2)
        #expect(Preferences(defaults: defaults).showCountInMenuBar)

        model.ignorePort(of: sampleListener)
        #expect(model.menuBarCount == 1, "ignored rows don't count")

        model.ignorePort(of: model.listeners.first { $0.pid == 7 }!)
        #expect(model.menuBarCount == nil, "an empty list shows no number")

        model.showCountInMenuBar = false
        #expect(!model.isPolling)
        #expect(model.menuBarCount == nil)
        let after = await runner.launches
        try await Task.sleep(for: .milliseconds(250))
        #expect(await runner.launches == after, "no polling once the badge is off")
    }

    @Test func badgeOnAtLaunchStartsPollingImmediately() async throws {
        let defaults = freshDefaults()
        Preferences(defaults: defaults).showCountInMenuBar = true
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let model = makeModel(runner: runner, defaults: defaults)
        #expect(model.isPolling)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await runner.launches >= 1)
        #expect(model.menuBarCount == 1)
    }

    @Test func popoverCadenceWinsWhileOpenThenFallsBackToBadge() async throws {
        let runner = FakeRunner(.success(lsofResult(sampleLsof)))
        let model = makeModel(runner: runner, badgeInterval: .seconds(30))
        model.showCountInMenuBar = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(await runner.launches == 1, "one background scan, next in 30 s")

        model.startPolling() // popover opened: refreshInterval (clamped 0.5 s) applies
        try await Task.sleep(for: .milliseconds(700))
        #expect(await runner.launches >= 2)

        model.stopPolling()
        #expect(model.isPolling, "badge keeps the loop alive after the popover closes")
    }

    @Test func openAndCopyGoThroughSystemActions() async {
        let actions = RecordingActions()
        let model = makeModel(actions: actions)
        model.open(sampleListener)
        model.copyURL(sampleListener)
        model.copyPort(sampleListener)
        model.copyPID(sampleListener)
        #expect(actions.opened.map(\.absoluteString) == ["http://localhost:3000"])
        #expect(actions.copied == ["http://localhost:3000", "3000", "42"])
    }
}

@MainActor
struct PreferencesTests {
    @Test func defaultsAndRoundTrip() {
        let prefs = Preferences(defaults: freshDefaults())
        #expect(prefs.refreshInterval == 2)
        #expect(prefs.showCountInMenuBar == false)
        prefs.refreshInterval = 5
        prefs.showCountInMenuBar = true
        #expect(prefs.refreshInterval == 5)
        #expect(prefs.showCountInMenuBar)
    }

    @Test func dockerIntegrationDefaultsOnAndPersists() {
        let defaults = freshDefaults()
        #expect(Preferences(defaults: defaults).dockerIntegration, "on by default: nothing runs without a docker CLI anyway")
        let model = PortListModel(
            scanner: PortScanner(runner: FakeRunner(.success(lsofResult(sampleLsof))), currentUID: 501, userName: testUserName, docker: nil),
            killer: KillRecorder(names: [:]).killer,
            actions: RecordingActions(),
            preferences: Preferences(defaults: defaults)
        )
        #expect(model.dockerIntegration)
        model.dockerIntegration = false
        #expect(Preferences(defaults: defaults).dockerIntegration == false)
    }

    @Test func refreshIntervalIsClamped() {
        let prefs = Preferences(defaults: freshDefaults())
        prefs.refreshInterval = 0.01
        #expect(prefs.refreshInterval == 0.5)
        prefs.refreshInterval = 999
        #expect(prefs.refreshInterval == 60)
        prefs.refreshInterval = -1
        #expect(prefs.refreshInterval == 2, "non-positive falls back to the default")
    }

    @Test func ignoreListsRoundTripAndDropInvalidPorts() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.ignoredPorts.isEmpty && prefs.ignoredProcessNames.isEmpty)
        prefs.ignoredPorts = [8080, 3000]
        prefs.ignoredProcessNames = ["node", "rapportd"]
        #expect(defaults.array(forKey: DefaultsKeys.ignoredPorts) as? [Int] == [3000, 8080])
        #expect(Preferences(defaults: defaults).ignoredPorts == [3000, 8080])
        #expect(Preferences(defaults: defaults).ignoredProcessNames == ["node", "rapportd"])
        defaults.set([70000, -1, 22], forKey: DefaultsKeys.ignoredPorts) // out-of-range junk
        #expect(Preferences(defaults: defaults).ignoredPorts == [22])
    }

    @Test func sortOrderFallsBackToPortOnUnknownValue() {
        let defaults = freshDefaults()
        defaults.set("bogus", forKey: DefaultsKeys.sortOrder)
        #expect(Preferences(defaults: defaults).sortOrder == .port)
    }

    @Test func thresholdIsClampedOnRead() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.highPortThreshold == 10_000, "unset reads as the default")
        defaults.set(0, forKey: DefaultsKeys.highPortThreshold)
        #expect(prefs.highPortThreshold == 10_000)
        defaults.set(999_999, forKey: DefaultsKeys.highPortThreshold)
        #expect(prefs.highPortThreshold == 65_535)
    }

    @Test func keysCarryThePrefix() {
        for key in [DefaultsKeys.refreshInterval, DefaultsKeys.showCountInMenuBar, DefaultsKeys.ignoredPorts, DefaultsKeys.ignoredProcessNames, DefaultsKeys.sortOrder, DefaultsKeys.hideHighPorts, DefaultsKeys.highPortThreshold] {
            #expect(key.hasPrefix("squatter."))
        }
        // The one deliberate exception: AppKit reads this exact string, so a `squatter.`
        // prefix would silently do nothing.
        #expect(DefaultsKeys.initialToolTipDelay == "NSInitialToolTipDelay")
    }

    /// The row's ⋯ / ↗ / ✕ chips only exist while the row is hovered, so AppKit's stock delay
    /// outlasts the time the pointer is over them.
    @Test func toolTipDelayIsShortenedForHoverRevealedChips() {
        // No "unset" precondition to assert: `register(defaults:)` writes to the process-wide
        // NSRegistrationDomain, which every suite consults, and the app under test registers it
        // at launch. That it is already visible here is the wiring working.
        let defaults = freshDefaults()
        Preferences.registerToolTipDelay(in: defaults)
        #expect(defaults.integer(forKey: DefaultsKeys.initialToolTipDelay) == Preferences.toolTipDelayMilliseconds)
        #expect(Preferences.toolTipDelayMilliseconds < 1_000, "must land while the chip is still under the cursor")
    }

    /// Registered, not set: the value stays in the registration domain, so it never lands in the
    /// user's plist and an explicit `defaults write` of the same key still wins.
    @Test func toolTipDelayDoesNotOverrideAnExplicitUserSetting() {
        let defaults = freshDefaults()
        defaults.set(1_500, forKey: DefaultsKeys.initialToolTipDelay)
        Preferences.registerToolTipDelay(in: defaults)
        #expect(defaults.integer(forKey: DefaultsKeys.initialToolTipDelay) == 1_500)
    }
}

private final class Anchor {}
