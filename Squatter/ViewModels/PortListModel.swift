import Foundation
import Observation

/// Per-row progress of a kill request.
enum KillState: Equatable, Sendable {
    /// Kill was requested; waiting for the user to confirm before any signal is sent.
    case confirming
    /// Force Kill was requested from the menu; waiting for confirmation before SIGKILL.
    case confirmingForce
    /// SIGTERM sent; waiting up to the grace period for the process to exit.
    case terminating
    /// Still alive after the grace period — the UI offers Force Kill.
    case stillRunning
    /// SIGKILL sent; waiting for exit.
    case forcing
    /// Stop Container was requested; waiting for confirmation before `docker stop`.
    case confirmingStop
    /// `docker stop` is running.
    case stopping
    case failed(String)
}

struct ListenerGroup: Identifiable, Equatable {
    enum Kind: Equatable { case yours, otherUsers, ignored }
    let kind: Kind
    let listeners: [Listener]
    var id: Kind { kind }
}

/// Why a row is hidden. The threshold is a rule, not a list entry, so the row's undo
/// action differs — see `PortRow.menuItems`.
enum IgnoreReason: Equatable, Sendable {
    case port
    case processName
    case highPort
}

/// Single source of truth for the popover. Views bind to it and hold no logic.
@MainActor
@Observable
final class PortListModel {
    private(set) var listeners: [Listener] = []
    /// Message from the most recent failed scan; `nil` once a scan succeeds again.
    private(set) var lastError: String?
    /// Drives the footer arrow's rotation. True only while a scan the *user* asked for is
    /// running — background polls leave it false, so the icon does not spin every couple of
    /// seconds — and held open for at least `minimumRefreshDisplay` so the turn completes.
    private(set) var isRefreshing = false
    /// False until the first scan completes, so the UI can distinguish "loading" from "empty".
    private(set) var hasLoaded = false
    private(set) var killStates: [Listener.ID: KillState] = [:]
    var filterText = ""
    var selection: Listener.ID?
    /// Reveal ignored rows (they render dimmed with an Unignore action).
    var showIgnored = false
    private(set) var ignoredPorts: Set<UInt16>
    private(set) var ignoredProcessNames: Set<String>
    var sortOrder: SortOrder {
        didSet { preferences.sortOrder = sortOrder }
    }
    /// Show the visible-listener count next to the menu bar icon. Turning it on polls in the
    /// background at `badgeInterval` while the popover is closed; off means popover-only polling.
    var showCountInMenuBar: Bool {
        didSet {
            preferences.showCountInMenuBar = showCountInMenuBar
            restartPollingLoop()
        }
    }
    /// Annotate Docker-published ports with their container. Off means Squatter never runs
    /// the `docker` CLI.
    var dockerIntegration: Bool {
        didSet {
            preferences.dockerIntegration = dockerIntegration
            let enabled = dockerIntegration
            Task { [scanner] in await scanner.setDockerEnabled(enabled) }
        }
    }

    /// Hide ports above `highPortThreshold` — most of them are macOS background services.
    var hideHighPorts: Bool {
        didSet {
            preferences.hideHighPorts = hideHighPorts
            clearSelectionIfHidden()
        }
    }

    var highPortThreshold: UInt16 {
        didSet {
            preferences.highPortThreshold = highPortThreshold
            clearSelectionIfHidden()
        }
    }

    @ObservationIgnored private let scanner: PortScanner
    @ObservationIgnored private let killer: ProcessKiller
    @ObservationIgnored private let stopper: ContainerStopper
    @ObservationIgnored private let actions: any SystemActions
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let forceKillGrace: Duration
    @ObservationIgnored private let forceKillWait: Duration
    @ObservationIgnored private let badgeInterval: Duration
    /// How long `isRefreshing` stays true at minimum, so the footer's rotating arrow completes a
    /// turn instead of twitching. A local `lsof` scan usually returns in well under 100 ms. Paired
    /// with the arrow's 5x rotation speed in `PortListView`: this is about one revolution, and
    /// raising it past that leaves the arrow spinning after the list has already settled.
    @ObservationIgnored private let minimumRefreshDisplay: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isPopoverVisible = false

    init(
        scanner: PortScanner = PortScanner(),
        killer: ProcessKiller = ProcessKiller(),
        stopper: ContainerStopper = ContainerStopper(),
        actions: any SystemActions = AppKitSystemActions(),
        preferences: Preferences = Preferences(),
        forceKillGrace: Duration = .seconds(2),
        forceKillWait: Duration = .seconds(1),
        badgeInterval: Duration = .seconds(10),
        minimumRefreshDisplay: Duration = .milliseconds(200)
    ) {
        self.scanner = scanner
        self.killer = killer
        self.stopper = stopper
        self.actions = actions
        self.preferences = preferences
        self.forceKillGrace = forceKillGrace
        self.forceKillWait = forceKillWait
        self.badgeInterval = badgeInterval
        self.minimumRefreshDisplay = minimumRefreshDisplay
        self.ignoredPorts = preferences.ignoredPorts
        self.ignoredProcessNames = preferences.ignoredProcessNames
        self.sortOrder = preferences.sortOrder
        self.showCountInMenuBar = preferences.showCountInMenuBar
        self.dockerIntegration = preferences.dockerIntegration
        self.hideHighPorts = preferences.hideHighPorts
        self.highPortThreshold = preferences.highPortThreshold
        // After every stored property is initialized: the capture list reads `self`, and
        // Swift's definite-initialization rejects that while any member is still unset.
        Task { [scanner, dockerIntegration] in await scanner.setDockerEnabled(dockerIntegration) }
        restartPollingLoop()
    }

    // MARK: Derived

    /// Listeners matching `filterText` (port, process name, PID), minus ignored rows unless
    /// `showIgnored`, in `sortOrder`.
    var filtered: [Listener] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let visible = listeners.filter { listener in
            guard showIgnored || !isIgnored(listener) else { return false }
            guard !query.isEmpty else { return true }
            return listener.processName.localizedCaseInsensitiveContains(query)
                || String(listener.port).contains(query)
                || String(listener.pid).contains(query)
        }
        switch sortOrder {
        case .port:
            return visible // scanner order: port, then name, then PID
        case .processName:
            return visible.sorted {
                let names = $0.processName.localizedCaseInsensitiveCompare($1.processName)
                guard names == .orderedSame else { return names == .orderedAscending }
                return ($0.port, $0.pid) < ($1.port, $1.pid)
            }
        case .pid:
            // Port breaks the tie: one process can hold several, and they would otherwise come
            // out in whatever order the scan produced.
            return visible.sorted { ($0.pid, $0.port) < ($1.pid, $1.port) }
        }
    }

    /// `filtered`, split into the groups the list renders. Order encodes what you can act on:
    /// your own processes first, other users' (not killable) next, ignored rows last when revealed.
    var groups: [ListenerGroup] {
        var yours: [Listener] = [], others: [Listener] = [], ignored: [Listener] = []
        for listener in filtered {
            if isIgnored(listener) { ignored.append(listener) }
            else if listener.isOwnedByCurrentUser { yours.append(listener) }
            else { others.append(listener) }
        }
        return [
            ListenerGroup(kind: .yours, listeners: yours),
            ListenerGroup(kind: .otherUsers, listeners: others),
            ListenerGroup(kind: .ignored, listeners: ignored),
        ].filter { !$0.listeners.isEmpty }
    }

    /// How many current listeners the ignore list hides (independent of the text filter).
    var hiddenCount: Int { listeners.count(where: isIgnored) }

    /// Why this listener is hidden, or `nil` when it is not.
    /// Order matters: an explicit list entry outranks the threshold rule, so a port the user
    /// ignored by hand still offers Unignore even when the rule would also hide it.
    func ignoreReason(_ listener: Listener) -> IgnoreReason? {
        if ignoredPorts.contains(listener.port) { return .port }
        if ignoredProcessNames.contains(listener.processName) { return .processName }
        if hideHighPorts, listener.port > highPortThreshold { return .highPort }
        return nil
    }

    func isIgnored(_ listener: Listener) -> Bool { ignoreReason(listener) != nil }

    var isPolling: Bool { pollTask != nil }

    /// Number to show in the menu bar, or `nil` when the badge is off, nothing has loaded yet,
    /// or the list is empty. Counts what the list would show with the ignore list applied.
    var menuBarCount: Int? {
        guard showCountInMenuBar, hasLoaded else { return nil }
        let count = listeners.count - hiddenCount
        return count > 0 ? count : nil
    }

    /// The selected row, if it is currently visible.
    var selectedListener: Listener? {
        filtered.first { $0.id == selection }
    }

    func killState(for listener: Listener) -> KillState? { killStates[listener.id] }

    // MARK: Refresh

    /// Popover appeared: scan now and every `refreshInterval` seconds until `stopPolling()`.
    func startPolling() {
        guard !isPopoverVisible else { return }
        isPopoverVisible = true
        restartPollingLoop()
    }

    /// Popover closed: back to background cadence if the badge is on, otherwise stop entirely.
    /// An armed confirmation is dropped — the model outlives the popover, and a Kill button
    /// left primed from a previous session is not a prompt the user is still answering.
    func stopPolling() {
        isPopoverVisible = false
        cancelAllKillConfirmations()
        restartPollingLoop()
    }

    /// One loop serves both cadences; the interval is re-read each tick so a settings change
    /// applies without restarting.
    private func restartPollingLoop() {
        pollTask?.cancel()
        pollTask = nil
        guard isPopoverVisible || showCountInMenuBar else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await scan(showingProgress: false)
                let interval = isPopoverVisible ? Duration.seconds(preferences.refreshInterval) : badgeInterval
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// A scan the user asked for — the Refresh button, ⌘R, or a Retry button. Shows progress.
    func refresh() async {
        await scan(showingProgress: true)
    }

    /// The scan itself. `showingProgress` drives `isRefreshing` and nothing else: a poll that
    /// ticks every couple of seconds would otherwise strobe the footer's arrow, which reads as a
    /// fault rather than as work. The list, the counts and the error still update either way, so
    /// the numbers stay current in both modes.
    private func scan(showingProgress: Bool) async {
        if showingProgress { isRefreshing = true }
        defer { if showingProgress { isRefreshing = false } }
        let started = ContinuousClock.now
        do {
            listeners = try await scanner.scan()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        hasLoaded = true
        let present = Set(listeners.map(\.id))
        killStates = killStates.filter { present.contains($0.key) }
        if let selection, !present.contains(selection) { self.selection = nil }
        // Hold the indicator open — *after* every line above, so the rows and counts are already
        // on screen and only the arrow is still turning. A scan that returns in 80 ms would
        // otherwise stop the rotation a fraction of a turn in, which reads as a twitch rather
        // than as a refresh. A slow scan overruns this and keeps spinning on its own.
        if showingProgress {
            let elapsed = ContinuousClock.now - started
            if elapsed < minimumRefreshDisplay {
                try? await Task.sleep(for: minimumRefreshDisplay - elapsed)
            }
        }
    }

    // MARK: Kill

    /// Arms the confirmation. Nothing is signalled until `kill(_:)`.
    /// Only one row can be armed at a time — arming a new one cancels the previous. A row
    /// Squatter mapped to a Docker container cannot arm a process kill at all — see
    /// `requestStopContainer(_:)`, which is the only destructive action available for it.
    func requestKill(_ listener: Listener) {
        guard listener.isOwnedByCurrentUser, listener.container == nil, killStates[listener.id] == nil else { return }
        cancelAllKillConfirmations()
        killStates[listener.id] = .confirming
    }

    /// Arms the Force Kill confirmation. Nothing is signalled until `forceKill(_:)`.
    func requestForceKill(_ listener: Listener) {
        guard listener.isOwnedByCurrentUser, listener.container == nil, killStates[listener.id] == nil else { return }
        cancelAllKillConfirmations()
        killStates[listener.id] = .confirmingForce
    }

    /// Arms the Stop Container confirmation. Nothing runs until `stopContainer(_:)`.
    /// Only rows Squatter mapped to a container can be armed — never a bare process. The
    /// guard is `container != nil`, **not** `isOwnedByCurrentUser`: the Docker proxy process
    /// may well be owned by the user, but what authorises this action is that Squatter
    /// identified a container, not who owns the proxy.
    func requestStopContainer(_ listener: Listener) {
        guard listener.container != nil, killStates[listener.id] == nil else { return }
        cancelAllKillConfirmations()
        killStates[listener.id] = .confirmingStop
    }

    func cancelKill(_ listener: Listener) {
        guard Self.isConfirming(killStates[listener.id]) else { return }
        killStates[listener.id] = nil
    }

    /// True while any row is waiting for confirmation — lets Escape cancel from the list.
    var isAwaitingKillConfirmation: Bool { killStates.values.contains(where: Self.isConfirming) }

    func cancelAllKillConfirmations() {
        killStates = killStates.filter { !Self.isConfirming($0.value) }
    }

    /// The two armed-but-unsignalled states. Anything else is a kill already in flight
    /// and must survive cancellation.
    private static func isConfirming(_ state: KillState?) -> Bool {
        state == .confirming || state == .confirmingForce || state == .confirmingStop
    }

    func kill(_ listener: Listener) async {
        guard listener.isOwnedByCurrentUser else { return }
        killStates[listener.id] = .terminating
        do {
            try killer.terminate(listener)
        } catch {
            killStates[listener.id] = .failed(error.localizedDescription)
            return
        }
        if await killer.waitForExit(of: listener, timeout: forceKillGrace) {
            killStates[listener.id] = nil
            await scan(showingProgress: false)
        } else {
            killStates[listener.id] = .stillRunning
        }
    }

    func forceKill(_ listener: Listener) async {
        guard listener.isOwnedByCurrentUser else { return }
        killStates[listener.id] = .forcing
        do {
            try killer.terminate(listener, force: true)
        } catch {
            killStates[listener.id] = .failed(error.localizedDescription)
            return
        }
        _ = await killer.waitForExit(of: listener, timeout: forceKillWait)
        killStates[listener.id] = nil
        await scan(showingProgress: false)
    }

    /// Runs `docker stop` and refreshes on success. The guard mirrors `requestStopContainer`:
    /// authorised by "Squatter identified a container", not by process ownership.
    func stopContainer(_ listener: Listener) async {
        guard let container = listener.container else { return }
        killStates[listener.id] = .stopping
        do {
            try await stopper.stop(container)
        } catch {
            killStates[listener.id] = .failed(error.localizedDescription)
            return
        }
        killStates[listener.id] = nil
        await scan(showingProgress: false)
    }

    func dismissKillError(for listener: Listener) {
        if case .failed = killStates[listener.id] { killStates[listener.id] = nil }
    }

    // MARK: Keyboard intents (act on the selection; return false when there is nothing to do)

    @discardableResult
    func openSelected() -> Bool {
        guard let listener = selectedListener else { return false }
        open(listener)
        return true
    }

    @discardableResult
    func copySelectedURL() -> Bool {
        guard let listener = selectedListener else { return false }
        copyURL(listener)
        return true
    }

    /// Arms the kill confirmation for the selected row. Refuses rows the user can't kill
    /// or that already have a kill in flight.
    @discardableResult
    func killSelected() -> Bool {
        guard let listener = selectedListener, killStates[listener.id] == nil else { return false }
        if listener.container != nil {
            requestStopContainer(listener)
            return true
        }
        guard listener.isOwnedByCurrentUser else { return false }
        requestKill(listener)
        return true
    }

    // MARK: Ignore list

    func ignorePort(of listener: Listener) {
        ignoredPorts.insert(listener.port)
        preferences.ignoredPorts = ignoredPorts
        clearSelectionIfHidden()
    }

    func ignoreProcess(of listener: Listener) {
        ignoredProcessNames.insert(listener.processName)
        preferences.ignoredProcessNames = ignoredProcessNames
        clearSelectionIfHidden()
    }

    /// Removes every rule that hides this listener (its port and its process name).
    func unignore(_ listener: Listener) {
        removeIgnoredPort(listener.port)
        removeIgnoredProcessName(listener.processName)
    }

    func removeIgnoredPort(_ port: UInt16) {
        ignoredPorts.remove(port)
        preferences.ignoredPorts = ignoredPorts
    }

    func removeIgnoredProcessName(_ name: String) {
        ignoredProcessNames.remove(name)
        preferences.ignoredProcessNames = ignoredProcessNames
    }

    /// Result of adding typed ports: what was added, and the tokens that were not ports.
    struct AddedPorts: Equatable, Sendable {
        var added: Set<UInt16> = []
        var skipped: [String] = []
    }

    /// Adds every port in `text` to the ignore list. Accepts commas, newlines, spaces and
    /// tabs as separators, so a pasted list works as-is. Tokens that are not a port in
    /// 1…65535 are returned in `skipped` rather than silently dropped.
    @discardableResult
    func addIgnoredPorts(from text: String) -> AddedPorts {
        var result = AddedPorts()
        let separators = CharacterSet(charactersIn: ",;\n\t ")
        for token in text.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let port = UInt16(trimmed), port > 0 else {
                result.skipped.append(trimmed)
                continue
            }
            result.added.insert(port)
        }
        guard !result.added.isEmpty else { return result }
        ignoredPorts.formUnion(result.added)
        preferences.ignoredPorts = ignoredPorts
        clearSelectionIfHidden()
        return result
    }

    /// Turns the whole threshold rule off — the undo for a row hidden by `.highPort`,
    /// which no list removal can reveal.
    func stopHidingHighPorts() { hideHighPorts = false }

    private func clearSelectionIfHidden() {
        guard let selection, !filtered.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
    }

    // MARK: Open / copy

    func open(_ listener: Listener) {
        guard let url = URL(string: listener.localURLString) else { return }
        actions.open(url)
    }

    func copyURL(_ listener: Listener) { actions.copy(listener.localURLString) }
    func copyPort(_ listener: Listener) { actions.copy(String(listener.port)) }
    func copyPID(_ listener: Listener) { actions.copy(String(listener.pid)) }
}
