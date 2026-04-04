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

  @MainActor
  @Observable
  public final class ConnectionSlice {
    public var connectionState: ConnectionState = .idle
    public var daemonStatus: DaemonStatusReport?
    public var diagnostics: DaemonDiagnosticsReport?
    public var health: HealthResponse?
    public var isRefreshing = false
    public var isDiagnosticsRefreshInFlight = false
    public var isDaemonActionInFlight = false
    public var activeTransport: TransportKind = .httpSSE
    public var connectionMetrics: ConnectionMetrics = .initial
    public var connectionEvents: [ConnectionEvent] = []
    public var subscribedSessionIDs: Set<String> = []
    public var isShowingCachedData = false
    public var persistedSessionCount = 0
    public var lastPersistedSnapshotAt: Date?
  }

  @MainActor
  @Observable
  public final class SelectionSlice {
    public var selectedSessionID: String?
    public var selectedSession: SessionDetail?
    public var timeline: [TimelineEntry] = []
    public var inspectorSelection: InspectorSelection = .none
    public var actionActorID: String?
    public var isSelectionLoading = false
    public var isSessionActionInFlight = false
  }

  @MainActor
  @Observable
  public final class UserDataSlice {
    public var bookmarkedSessionIds: Set<String> = []

    public init() {}
  }

  public let connection = ConnectionSlice()
  public let sessionIndex = SessionIndexSlice()
  public let selection = SelectionSlice()
  public let userData = UserDataSlice()

  public var lastAction = ""
  public var lastError: String?
  public var persistenceError: String?
  public var pendingConfirmation: PendingConfirmation?
  public var showConfirmation: Bool {
    get { pendingConfirmation != nil }
    set { if !newValue { cancelConfirmation() } }
  }
  public var navigationBackStack: [String?] = []
  public var navigationForwardStack: [String?] = []
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
  var isNavigatingHistory = false
  private var hasBootstrapped = false
  private var lastActionDismissTask: Task<Void, Never>?

  public init(
    daemonController: any DaemonControlling,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil
  ) {
    self.daemonController = daemonController
    self.modelContext = modelContainer?.mainContext
    if let modelContainer {
      self.cacheService = SessionCacheService(modelContainer: modelContainer)
    } else {
      self.cacheService = nil
    }
    self.persistenceError = persistenceError
    refreshBookmarkedSessionIds()
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

    async let daemonStatusResponse: DaemonStatusReport? = try? daemonController.daemonStatus()

    do {
      let client = try await daemonController.bootstrapClient()
      await connect(using: client)
      daemonStatus = await daemonStatusResponse
    } catch {
      daemonStatus = await daemonStatusResponse
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

  public func startDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let client = try await daemonController.startDaemonClient()
      async let daemonStatusResponse: DaemonStatusReport? = try? daemonController.daemonStatus()
      try? await Task.sleep(for: .milliseconds(300))
      await connect(using: client)
      daemonStatus = await daemonStatusResponse
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
      async let diagnosticsResponse = Self.measureOperation {
        try await client.diagnostics()
      }
      async let daemonStatusResponse: DaemonStatusReport? = try? daemonController.daemonStatus()
      let measuredDiagnostics = try await diagnosticsResponse
      diagnostics = measuredDiagnostics.value
      health = measuredDiagnostics.value.health
      recordRequestSuccess()
      daemonStatus = await daemonStatusResponse
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
