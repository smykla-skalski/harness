import Foundation
import Observation
import SwiftData

@MainActor
@Observable
public final class HarnessMonitorStore {
  public enum ConnectionState: Equatable {
    case idle
    case connecting
    case online
    case offline(String)
  }

  public enum SessionFilter: String, CaseIterable, Identifiable {
    case active
    case all
    case ended

    public var id: String { rawValue }

    public var title: String {
      rawValue.capitalized
    }

    func includes(_ status: SessionStatus) -> Bool {
      switch self {
      case .active:
        status != .ended
      case .all:
        true
      case .ended:
        status == .ended
      }
    }
  }

  public enum InspectorSelection: Equatable {
    case none
    case task(String)
    case agent(String)
    case signal(String)
    case observer
  }

  public enum PendingConfirmation: Equatable {
    case endSession(sessionID: String, actorID: String)
    case removeAgent(sessionID: String, agentID: String, actorID: String)
  }

  public enum PresentedSheet: Identifiable, Equatable {
    case sendSignal(agentID: String)

    public var id: String {
      switch self {
      case .sendSignal(let agentID): "sendSignal:\(agentID)"
      }
    }
  }

  public struct CheckoutGroup: Identifiable, Equatable {
    public let checkoutId: String
    public let title: String
    public let isWorktree: Bool
    public let sessions: [SessionSummary]

    public var id: String { checkoutId }
  }

  public struct SessionGroup: Identifiable, Equatable {
    public let project: ProjectSummary
    public let checkoutGroups: [CheckoutGroup]

    public var sessions: [SessionSummary] {
      checkoutGroups.flatMap(\.sessions)
    }

    public var id: String { project.id }
  }

  public enum StatusMessageTone: Equatable {
    case secondary
    case info
    case success
    case caution
  }

  public struct StatusMessageState: Equatable, Identifiable {
    public let id: String
    public let text: String
    public let systemImage: String?
    public let tone: StatusMessageTone

    public init(
      id: String,
      text: String,
      systemImage: String? = nil,
      tone: StatusMessageTone = .secondary
    ) {
      self.id = id
      self.text = text
      self.systemImage = systemImage
      self.tone = tone
    }
  }

  public enum DaemonIndicatorState: Equatable {
    case offline
    case launchdConnected
    case manualConnected
  }

  public struct ToolbarMetricsState: Equatable {
    public var projectCount = 0
    public var worktreeCount = 0
    public var sessionCount = 0
    public var openWorkCount = 0
    public var blockedCount = 0

    public init(
      projectCount: Int = 0,
      worktreeCount: Int = 0,
      sessionCount: Int = 0,
      openWorkCount: Int = 0,
      blockedCount: Int = 0
    ) {
      self.projectCount = projectCount
      self.worktreeCount = worktreeCount
      self.sessionCount = sessionCount
      self.openWorkCount = openWorkCount
      self.blockedCount = blockedCount
    }
  }

  public enum SidebarEmptyState: Equatable {
    case noSessions
    case noMatches
    case sessionsAvailable
  }

  public struct SidebarFilterSummaryState: Equatable {
    public var activeFilterSummary: String
    public var isFiltered: Bool

    public init(
      activeFilterSummary: String = "0 indexed",
      isFiltered: Bool = false
    ) {
      self.activeFilterSummary = activeFilterSummary
      self.isFiltered = isFiltered
    }
  }

  public struct InspectorTaskSelectionState: Equatable {
    public let task: WorkItem
    public let notesSessionID: String?
    public let isPersistenceAvailable: Bool

    public init(
      task: WorkItem,
      notesSessionID: String?,
      isPersistenceAvailable: Bool
    ) {
      self.task = task
      self.notesSessionID = notesSessionID
      self.isPersistenceAvailable = isPersistenceAvailable
    }
  }

  public struct InspectorAgentSelectionState: Equatable {
    public let agent: AgentRegistration
    public let activity: AgentToolActivitySummary?

    public init(
      agent: AgentRegistration,
      activity: AgentToolActivitySummary?
    ) {
      self.agent = agent
      self.activity = activity
    }
  }

  public enum InspectorPrimaryContentState: Equatable {
    case empty
    case loading(SessionSummary)
    case session(SessionDetail)
    case task(InspectorTaskSelectionState)
    case agent(InspectorAgentSelectionState)
    case signal(SessionSignalRecord)
    case observer(ObserverSummary)

    public var identity: String {
      switch self {
      case .empty:
        return "empty"
      case .loading(let summary):
        return "loading:\(summary.sessionId)"
      case .session(let detail):
        return "session:\(detail.session.sessionId)"
      case .task(let selection):
        return "task:\(selection.task.taskId)"
      case .agent(let selection):
        return "agent:\(selection.agent.agentId)"
      case .signal(let signal):
        return "signal:\(signal.signal.signalId)"
      case .observer(let observer):
        return "observer:\(observer.observeId)"
      }
    }

    public var observer: ObserverSummary? {
      guard case .observer(let observer) = self else {
        return nil
      }
      return observer
    }

    public init(
      selectedSession: SessionDetail?,
      selectedSessionSummary: SessionSummary?,
      inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool
    ) {
      guard let selectedSession else {
        if let selectedSessionSummary {
          self = .loading(selectedSessionSummary)
        } else {
          self = .empty
        }
        return
      }

      self = Self.resolveSelection(
        selectedSession: selectedSession,
        inspectorSelection: inspectorSelection,
        isPersistenceAvailable: isPersistenceAvailable
      )
    }

    private static func resolveSelection(
      selectedSession: SessionDetail,
      inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool
    ) -> Self {
      switch inspectorSelection {
      case .none:
        return .session(selectedSession)
      case .task(let taskID):
        guard let task = selectedSession.tasks.first(where: { $0.taskId == taskID }) else {
          return .session(selectedSession)
        }
        return .task(
          InspectorTaskSelectionState(
            task: task,
            notesSessionID: selectedSession.session.sessionId,
            isPersistenceAvailable: isPersistenceAvailable
          )
        )
      case .agent(let agentID):
        guard let agent = selectedSession.agents.first(where: { $0.agentId == agentID }) else {
          return .session(selectedSession)
        }
        return .agent(
          InspectorAgentSelectionState(
            agent: agent,
            activity: selectedSession.agentActivity.first(where: { $0.agentId == agent.agentId })
          )
        )
      case .signal(let signalID):
        guard let signal = selectedSession.signals.first(where: { $0.signal.signalId == signalID }) else {
          return .session(selectedSession)
        }
        return .signal(signal)
      case .observer:
        if let observer = selectedSession.observer {
          return .observer(observer)
        }
        return .session(selectedSession)
      }
    }
  }

  public struct InspectorActionContext: Equatable {
    public let detail: SessionDetail
    public let selectedTask: WorkItem?
    public let selectedAgent: AgentRegistration?
    public let selectedObserver: ObserverSummary?
    public let isPersistenceAvailable: Bool
    public let availableActionActors: [AgentRegistration]
    public let selectedActionActorID: String
    public let isSessionReadOnly: Bool
    public let isSessionActionInFlight: Bool
    public let lastAction: String
    public let lastError: String?

    public init(
      detail: SessionDetail,
      selectedTask: WorkItem?,
      selectedAgent: AgentRegistration?,
      selectedObserver: ObserverSummary?,
      isPersistenceAvailable: Bool,
      availableActionActors: [AgentRegistration],
      selectedActionActorID: String,
      isSessionReadOnly: Bool,
      isSessionActionInFlight: Bool,
      lastAction: String,
      lastError: String?
    ) {
      self.detail = detail
      self.selectedTask = selectedTask
      self.selectedAgent = selectedAgent
      self.selectedObserver = selectedObserver
      self.isPersistenceAvailable = isPersistenceAvailable
      self.availableActionActors = availableActionActors
      self.selectedActionActorID = selectedActionActorID
      self.isSessionReadOnly = isSessionReadOnly
      self.isSessionActionInFlight = isSessionActionInFlight
      self.lastAction = lastAction
      self.lastError = lastError
    }
  }

  @MainActor
  @Observable
  public final class ConnectionSlice {
    public enum Change {
      case shellState
      case metrics
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public var connectionState: ConnectionState = .idle {
      didSet { onChanged?(.shellState) }
    }
    public var daemonStatus: DaemonStatusReport? {
      didSet { onChanged?(.shellState) }
    }
    public var diagnostics: DaemonDiagnosticsReport?
    public var health: HealthResponse?
    public var isRefreshing = false {
      didSet { onChanged?(.shellState) }
    }
    public var isDiagnosticsRefreshInFlight = false
    public var isDaemonActionInFlight = false {
      didSet { onChanged?(.shellState) }
    }
    public var activeTransport: TransportKind = .httpSSE
    public var connectionMetrics: ConnectionMetrics = .initial {
      didSet { onChanged?(.metrics) }
    }
    public var connectionEvents: [ConnectionEvent] = []
    public var subscribedSessionIDs: Set<String> = []
    public var daemonLogLevel: String?
    public var isShowingCachedData = false {
      didSet { onChanged?(.shellState) }
    }
    public var persistedSessionCount = 0 {
      didSet { onChanged?(.shellState) }
    }
    public var lastPersistedSnapshotAt: Date? {
      didSet { onChanged?(.shellState) }
    }
  }

  @MainActor
  @Observable
  public final class SelectionSlice {
    public enum Change {
      case selectedSessionID
      case selectedSession
      case timeline
      case inspectorSelection
      case actionActorID
      case selectionLoading
      case extensionsLoading
      case sessionAction
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public var selectedSessionID: String? {
      didSet { onChanged?(.selectedSessionID) }
    }
    public var selectedSession: SessionDetail? {
      didSet { onChanged?(.selectedSession) }
    }
    public var timeline: [TimelineEntry] = [] {
      didSet { onChanged?(.timeline) }
    }
    public var inspectorSelection: InspectorSelection = .none {
      didSet { onChanged?(.inspectorSelection) }
    }
    public var actionActorID: String? {
      didSet { onChanged?(.actionActorID) }
    }
    public var isSelectionLoading = false {
      didSet { onChanged?(.selectionLoading) }
    }
    public var isExtensionsLoading = false {
      didSet { onChanged?(.extensionsLoading) }
    }
    public var isSessionActionInFlight = false {
      didSet { onChanged?(.sessionAction) }
    }
  }

  @MainActor
  @Observable
  public final class UserDataSlice {
    @ObservationIgnored public var onChanged: (() -> Void)?
    public var bookmarkedSessionIds: Set<String> = [] {
      didSet { onChanged?() }
    }

    public init() {}
  }

  @MainActor
  @Observable
  public final class ContentUISlice {
    public var selectedSessionID: String?
    public var selectedDetail: SessionDetail?
    public var selectedSessionSummary: SessionSummary?
    public var timeline: [TimelineEntry] = []
    public var windowTitle = "Dashboard"
    public var persistenceError: String?
    public var sessionDataAvailability: SessionDataAvailability = .live
    public var sessionStatus: SessionStatus?
    public var toolbarMetrics = ToolbarMetricsState()
    public var statusMessages: [StatusMessageState] = []
    public var daemonIndicator: DaemonIndicatorState = .offline
    public var isLaunchAgentInstalled = false
    public var isBusy = false
    public var canNavigateBack = false
    public var canNavigateForward = false
    public var connectionState: ConnectionState = .idle
    public var isSessionReadOnly = true
    public var isSessionActionInFlight = false
    public var isRefreshing = false
    public var isSelectionLoading = false
    public var isExtensionsLoading = false
    public var lastAction = ""
    public var pendingConfirmation: PendingConfirmation?
    public var presentedSheet: PresentedSheet?
    public var sleepPreventionEnabled = false
  }

  @MainActor
  @Observable
  public final class SidebarUISlice {
    public var connectionState: ConnectionState = .idle
    public var isBusy = false
    public var isRefreshing = false
    public var isLaunchAgentInstalled = false
    public var connectionMetrics: ConnectionMetrics = .initial
    public var selectedSessionID: String?
    public var isPersistenceAvailable = false
    public var bookmarkedSessionIds: Set<String> = []
    public var emptyState: SidebarEmptyState = .noSessions
    public var filterSummary = SidebarFilterSummaryState()
  }

  @MainActor
  @Observable
  public final class InspectorUISlice {
    public var primaryContent: InspectorPrimaryContentState = .empty
    public var actionContext: InspectorActionContext?
  }

  public let connection: ConnectionSlice
  public let sessionIndex: SessionIndexSlice
  public let selection: SelectionSlice
  public let userData: UserDataSlice
  public let contentUI: ContentUISlice
  public let sidebarUI: SidebarUISlice
  public let inspectorUI: InspectorUISlice

  public var lastAction = "" {
    didSet { scheduleUISync([.content, .inspector]) }
  }
  public var lastError: String? {
    didSet { scheduleUISync([.inspector]) }
  }
  public var persistenceError: String? {
    didSet { scheduleUISync([.content, .sidebar, .inspector]) }
  }
  public var presentedSheet: PresentedSheet? {
    didSet { scheduleUISync([.content]) }
  }
  public var pendingConfirmation: PendingConfirmation? {
    didSet { scheduleUISync([.content]) }
  }
  public var showConfirmation: Bool {
    get { pendingConfirmation != nil }
    set { if !newValue { cancelConfirmation() } }
  }
  public var sleepPreventionEnabled = false {
    didSet {
      sleepAssertion.update(hasActiveSessions: sleepPreventionEnabled)
      scheduleUISync([.content])
    }
  }
  public var navigationBackStack: [String?] = [] {
    didSet { scheduleUISync([.content]) }
  }
  public var navigationForwardStack: [String?] = [] {
    didSet { scheduleUISync([.content]) }
  }
  var connectionProbeInterval: Duration = .seconds(10)
  var lastActionDismissDelay: Duration = .seconds(4)

  let daemonController: any DaemonControlling
  public let modelContext: ModelContext?
  let cacheService: SessionCacheService?
  var client: (any HarnessMonitorClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
  var connectionProbeTask: Task<Void, Never>?
  var sessionPushFallbackTask: Task<Void, Never>?
  var sessionSnapshotHydrationTask: Task<Void, Never>?
  var selectionTask: Task<Void, Never>?
  var pendingCacheWriteTask: Task<Void, Never>?
  var manifestWatcher: ManifestWatcher?
  var latencySamplesMs: [Int] = []
  var trafficSampleTimes: [Date] = []
  var activeSessionLoadRequest: UInt64 = 0
  var sessionLoadSequence: UInt64 = 0
  var sessionPushFallbackSequence: UInt64 = 0
  var pendingSessionPushFallback: (sessionID: String, token: UInt64)?
  var pendingExtensions: SessionExtensionsPayload?
  var isNavigatingHistory = false
  private var hasBootstrapped = false
  private var lastActionDismissTask: Task<Void, Never>?
  private let sleepAssertion = SleepAssertion()
  @ObservationIgnored private var pendingUISyncAreas: Set<UISyncArea> = []
  @ObservationIgnored private var isApplyingUISyncBatch = false

  public init(
    daemonController: any DaemonControlling,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil
  ) {
    self.connection = ConnectionSlice()
    self.sessionIndex = SessionIndexSlice()
    self.selection = SelectionSlice()
    self.userData = UserDataSlice()
    self.contentUI = ContentUISlice()
    self.sidebarUI = SidebarUISlice()
    self.inspectorUI = InspectorUISlice()
    self.daemonController = daemonController
    self.modelContext = modelContainer?.mainContext
    if let modelContainer {
      self.cacheService = SessionCacheService(modelContainer: modelContainer)
    } else {
      self.cacheService = nil
    }
    self.persistenceError = persistenceError
    bindUISlices()
    refreshBookmarkedSessionIds()
    syncAllUI()
  }

  public func bootstrapIfNeeded() async {
    guard !hasBootstrapped else {
      return
    }
    hasBootstrapped = true
    refreshBookmarkedSessionIds()
    await refreshPersistedSessionMetadata()
    await bootstrap()
  }

  public func bootstrap() async {
    connectionState = .connecting
    lastError = nil

    do {
      let client = try await daemonController.bootstrapClient()
      await connect(using: client)
      daemonStatus = try? await daemonController.daemonStatus()
    } catch {
      daemonStatus = try? await daemonController.daemonStatus()
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

  public func startDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let client = try await daemonController.startDaemonClient()
      try? await Task.sleep(for: .milliseconds(300))
      await connect(using: client)
      daemonStatus = try? await daemonController.daemonStatus()
    } catch {
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

  public func stopDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.stopDaemon()
      stopAllStreams()
      stopManifestWatcher()
      client = nil
      markConnectionOffline("Daemon stopped")
      await refreshDaemonStatus()
      await restorePersistedSessionState()
      showLastAction("Stop daemon")
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func installLaunchAgent() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.installLaunchAgent()
      await refreshDaemonStatus()
      showLastAction("Install launch agent")
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func removeLaunchAgent() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.removeLaunchAgent()
      await refreshDaemonStatus()
      showLastAction("Remove launch agent")
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func refreshDaemonStatus() async {
    do {
      daemonStatus = try await daemonController.daemonStatus()
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func reconnect() async {
    stopAllStreams()
    client = nil
    hasBootstrapped = true
    await bootstrap()
  }

  public func prepareForTermination() async {
    clearLastAction()
    stopAllStreams()
    stopManifestWatcher()

    guard let client else {
      return
    }

    self.client = nil
    await client.shutdown()
  }

  public func refreshDiagnostics() async {
    isDiagnosticsRefreshInFlight = true
    defer { isDiagnosticsRefreshInFlight = false }

    guard let client else {
      await refreshDaemonStatus()
      diagnostics = nil
      return
    }

    do {
      let measuredDiagnostics = try await Self.measureOperation {
        try await client.diagnostics()
      }
      diagnostics = measuredDiagnostics.value
      health = measuredDiagnostics.value.health
      recordRequestSuccess()
      daemonStatus = try? await daemonController.daemonStatus()
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func refresh() async {
    guard let client else {
      await bootstrap()
      return
    }
    await refresh(using: client, preserveSelection: true)
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.daemonStatus = try? await self.daemonController.daemonStatus()
    }
  }

  public func configureUITestBehavior(lastActionDismissDelay: Duration) {
    self.lastActionDismissDelay = lastActionDismissDelay
  }

  public func showLastAction(_ action: String) {
    lastActionDismissTask?.cancel()
    lastAction = action

    guard !action.isEmpty else {
      lastActionDismissTask = nil
      return
    }

    let delay = lastActionDismissDelay
    lastActionDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, self.lastAction == action else {
        return
      }
      self.lastAction = ""
      self.lastActionDismissTask = nil
    }
  }

  public func clearLastAction() {
    lastActionDismissTask?.cancel()
    lastActionDismissTask = nil
    lastAction = ""
  }
  func stopGlobalStream() {
    globalStreamTask?.cancel()
    globalStreamTask = nil
  }

  func stopSessionStream(resetSubscriptions: Bool = true) {
    sessionStreamTask?.cancel()
    sessionStreamTask = nil
    if resetSubscriptions {
      subscribedSessionIDs.removeAll()
    }
  }

  func stopAllStreams(resetSubscriptions: Bool = true) {
    stopGlobalStream()
    stopSessionStream(resetSubscriptions: resetSubscriptions)
    stopConnectionProbe()
    cancelSessionPushFallback()
    sessionSnapshotHydrationTask?.cancel()
    sessionSnapshotHydrationTask = nil
  }
}

private extension HarnessMonitorStore {
  enum UISyncArea: Hashable {
    case content
    case sidebar
    case inspector
  }
}

extension HarnessMonitorStore {
  func withUISyncBatch(_ body: () -> Void) {
    let wasApplyingBatch = isApplyingUISyncBatch
    isApplyingUISyncBatch = true
    body()
    isApplyingUISyncBatch = wasApplyingBatch
    if !wasApplyingBatch {
      flushPendingUISync()
    }
  }

  private func bindUISlices() {
    connection.onChanged = { [weak self] change in
      switch change {
      case .shellState:
        self?.scheduleUISync([.content, .sidebar, .inspector])
      case .metrics:
        self?.scheduleUISync([.sidebar])
      }
    }
    selection.onChanged = { [weak self] change in
      switch change {
      case .selectedSessionID:
        self?.scheduleUISync([.content, .sidebar, .inspector])
      case .selectedSession:
        self?.scheduleUISync([.content, .inspector])
      case .timeline:
        self?.scheduleUISync([.content])
      case .inspectorSelection, .actionActorID:
        self?.scheduleUISync([.inspector])
      case .selectionLoading, .extensionsLoading:
        self?.scheduleUISync([.content])
      case .sessionAction:
        self?.scheduleUISync([.content, .inspector])
      }
    }
    userData.onChanged = { [weak self] in
      self?.scheduleUISync([.sidebar])
    }
    sessionIndex.onChanged = { [weak self] change in
      switch change {
      case .data:
        self?.scheduleUISync([.content, .sidebar, .inspector])
      case .projection:
        self?.scheduleUISync([.sidebar])
      }
    }
  }

  private func scheduleUISync(_ area: UISyncArea) {
    scheduleUISync([area])
  }

  private func scheduleUISync(_ areas: Set<UISyncArea>) {
    pendingUISyncAreas.formUnion(areas)
    if !isApplyingUISyncBatch {
      flushPendingUISync()
    }
  }

  private func flushPendingUISync() {
    guard !pendingUISyncAreas.isEmpty else {
      return
    }

    let areas = pendingUISyncAreas
    pendingUISyncAreas.removeAll()
    syncUI(areas)
  }

  private func syncAllUI() {
    syncUI([.content, .sidebar, .inspector])
  }

  private func syncUI(_ areas: Set<UISyncArea>) {
    if areas.contains(.content) {
      syncContentUI()
    }
    if areas.contains(.sidebar) {
      syncSidebarUI()
    }
    if areas.contains(.inspector) {
      syncInspectorUI()
    }
  }

  private func syncContentUI() {
    let selectedDetail = matchedSelectedDetail()
    let selectedSessionSummary = sessionIndex.sessionSummary(for: selection.selectedSessionID)
    let toolbarMetrics = ToolbarMetricsState(
      projectCount: daemonStatus?.projectCount ?? sessionIndex.projects.count,
      worktreeCount: daemonStatus?.worktreeCount
        ?? sessionIndex.projects.reduce(0) { $0 + $1.worktrees.count },
      sessionCount: daemonStatus?.sessionCount ?? sessionIndex.sessions.count,
      openWorkCount: sessionIndex.totalOpenWorkCount,
      blockedCount: sessionIndex.totalBlockedCount
    )

    assign(selection.selectedSessionID, to: \.selectedSessionID, on: contentUI)
    assign(selectedDetail, to: \.selectedDetail, on: contentUI)
    assign(selectedSessionSummary, to: \.selectedSessionSummary, on: contentUI)
    assign(selection.timeline, to: \.timeline, on: contentUI)
    assign(
      selectedDetail != nil || selectedSessionSummary != nil ? "Cockpit" : "Dashboard",
      to: \.windowTitle,
      on: contentUI
    )
    assign(persistenceError, to: \.persistenceError, on: contentUI)
    assign(sessionDataAvailability, to: \.sessionDataAvailability, on: contentUI)
    assign(
      selectedDetail?.session.status ?? selectedSessionSummary?.status,
      to: \.sessionStatus,
      on: contentUI
    )
    assign(toolbarMetrics, to: \.toolbarMetrics, on: contentUI)
    assign(resolveStatusMessages(sessionCount: toolbarMetrics.sessionCount), to: \.statusMessages, on: contentUI)
    assign(resolveDaemonIndicatorState(), to: \.daemonIndicator, on: contentUI)
    assign(daemonStatus?.launchAgent.installed == true, to: \.isLaunchAgentInstalled, on: contentUI)
    assign(isBusy, to: \.isBusy, on: contentUI)
    assign(canNavigateBack, to: \.canNavigateBack, on: contentUI)
    assign(canNavigateForward, to: \.canNavigateForward, on: contentUI)
    assign(connectionState, to: \.connectionState, on: contentUI)
    assign(isSessionReadOnly, to: \.isSessionReadOnly, on: contentUI)
    assign(isSessionActionInFlight, to: \.isSessionActionInFlight, on: contentUI)
    assign(isRefreshing, to: \.isRefreshing, on: contentUI)
    assign(isSelectionLoading, to: \.isSelectionLoading, on: contentUI)
    assign(isExtensionsLoading, to: \.isExtensionsLoading, on: contentUI)
    assign(lastAction, to: \.lastAction, on: contentUI)
    assign(pendingConfirmation, to: \.pendingConfirmation, on: contentUI)
    assign(presentedSheet, to: \.presentedSheet, on: contentUI)
    assign(sleepPreventionEnabled, to: \.sleepPreventionEnabled, on: contentUI)
  }

  private func syncSidebarUI() {
    assign(connectionState, to: \.connectionState, on: sidebarUI)
    assign(isBusy, to: \.isBusy, on: sidebarUI)
    assign(isRefreshing, to: \.isRefreshing, on: sidebarUI)
    assign(daemonStatus?.launchAgent.installed == true, to: \.isLaunchAgentInstalled, on: sidebarUI)
    assign(connectionMetrics, to: \.connectionMetrics, on: sidebarUI)
    assign(selection.selectedSessionID, to: \.selectedSessionID, on: sidebarUI)
    assign(isPersistenceAvailable, to: \.isPersistenceAvailable, on: sidebarUI)
    assign(userData.bookmarkedSessionIds, to: \.bookmarkedSessionIds, on: sidebarUI)
    assign(resolveSidebarEmptyState(), to: \.emptyState, on: sidebarUI)
    assign(resolveSidebarFilterSummary(), to: \.filterSummary, on: sidebarUI)
  }

  private func syncInspectorUI() {
    let selectedDetail = matchedSelectedDetail()
    let selectedSessionSummary = sessionIndex.sessionSummary(for: selection.selectedSessionID)

    assign(
      InspectorPrimaryContentState(
        selectedSession: selectedDetail,
        selectedSessionSummary: selectedSessionSummary,
        inspectorSelection: selection.inspectorSelection,
        isPersistenceAvailable: isPersistenceAvailable
      ),
      to: \.primaryContent,
      on: inspectorUI
    )
    assign(resolveInspectorActionContext(detail: selectedDetail), to: \.actionContext, on: inspectorUI)
  }

  private func matchedSelectedDetail() -> SessionDetail? {
    guard let sessionID = selection.selectedSessionID,
      let detail = selection.selectedSession,
      detail.session.sessionId == sessionID
    else {
      return nil
    }
    return detail
  }

  private func resolveStatusMessages(sessionCount: Int) -> [StatusMessageState] {
    var messages: [StatusMessageState] = []

    if connectionState == .connecting {
      messages.append(
        .init(
          id: "loading.connecting",
          text: "Connecting to the control plane",
          systemImage: "network",
          tone: .caution
        )
      )
    }
    if isRefreshing {
      messages.append(
        .init(
          id: "loading.refreshing",
          text: "Refreshing session index",
          systemImage: "arrow.trianglehead.2.clockwise",
          tone: .caution
        )
      )
    }
    if isSelectionLoading {
      messages.append(
        .init(
          id: "loading.session",
          text: "Loading session detail",
          systemImage: "doc.text.magnifyingglass",
          tone: .caution
        )
      )
    }
    if isExtensionsLoading {
      messages.append(
        .init(
          id: "loading.extensions",
          text: "Loading observers and signals",
          systemImage: "antenna.radiowaves.left.and.right",
          tone: .caution
        )
      )
    }

    messages.append(contentsOf: [
      .init(
        id: "status.running",
        text: "Running Harness Monitor",
        systemImage: "gearshape.fill",
        tone: .info
      ),
      .init(
        id: "status.sessions",
        text: "\(sessionCount) sessions active",
        systemImage: "antenna.radiowaves.left.and.right",
        tone: .success
      ),
      .init(
        id: "status.daemon",
        text: "Daemon connected",
        systemImage: "checkmark.circle.fill",
        tone: .success
      ),
    ])

    return messages
  }

  private func resolveDaemonIndicatorState() -> DaemonIndicatorState {
    guard connectionState == .online else {
      return .offline
    }
    if daemonStatus?.launchAgent.installed == true {
      return .launchdConnected
    }
    return .manualConnected
  }

  private func resolveSidebarEmptyState() -> SidebarEmptyState {
    if sessionIndex.sessions.isEmpty {
      return .noSessions
    }
    if sessionIndex.groupedSessions.isEmpty {
      return .noMatches
    }
    return .sessionsAvailable
  }

  private func resolveSidebarFilterSummary() -> SidebarFilterSummaryState {
    let isFiltered =
      !sessionIndex.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || sessionIndex.sessionFilter != .active
      || sessionIndex.sessionFocusFilter != .all

    if isFiltered {
      return SidebarFilterSummaryState(
        activeFilterSummary:
          "\(sessionIndex.filteredSessionCount) visible of \(sessionIndex.sessions.count)",
        isFiltered: true
      )
    }

    return SidebarFilterSummaryState(
      activeFilterSummary: "\(sessionIndex.sessions.count) indexed",
      isFiltered: false
    )
  }

  private func resolveInspectorActionContext(
    detail: SessionDetail?
  ) -> InspectorActionContext? {
    guard let detail else {
      return nil
    }

    let selectedTask: WorkItem?
    if case .task(let taskID) = selection.inspectorSelection {
      selectedTask = detail.tasks.first(where: { $0.taskId == taskID })
    } else {
      selectedTask = nil
    }

    let selectedAgent: AgentRegistration?
    if case .agent(let agentID) = selection.inspectorSelection {
      selectedAgent = detail.agents.first(where: { $0.agentId == agentID })
    } else {
      selectedAgent = nil
    }

    let selectedObserver: ObserverSummary?
    if case .observer = selection.inspectorSelection {
      selectedObserver = detail.observer
    } else {
      selectedObserver = nil
    }

    return InspectorActionContext(
      detail: detail,
      selectedTask: selectedTask,
      selectedAgent: selectedAgent,
      selectedObserver: selectedObserver,
      isPersistenceAvailable: isPersistenceAvailable,
      availableActionActors: detail.agents.filter { $0.status == .active },
      selectedActionActorID: resolvedActionActor() ?? "",
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight,
      lastAction: lastAction,
      lastError: lastError
    )
  }

  private func assign<Root: AnyObject, Value: Equatable>(
    _ value: Value,
    to keyPath: ReferenceWritableKeyPath<Root, Value>,
    on root: Root
  ) {
    guard root[keyPath: keyPath] != value else {
      return
    }
    root[keyPath: keyPath] = value
  }
}
