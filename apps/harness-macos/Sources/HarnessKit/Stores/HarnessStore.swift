import Foundation
import Observation
import SwiftData

@MainActor
@Observable
public final class HarnessStore {
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

  public struct SessionGroup: Identifiable, Equatable {
    public let project: ProjectSummary
    public let sessions: [SessionSummary]

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
  var client: (any HarnessClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
  var connectionProbeTask: Task<Void, Never>?
  var sessionPushFallbackTask: Task<Void, Never>?
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
    modelContext: ModelContext? = nil,
    persistenceError: String? = nil
  ) {
    self.daemonController = daemonController
    self.modelContext = modelContext
    self.persistenceError = persistenceError
    refreshBookmarkedSessionIds()
  }

  public func bootstrapIfNeeded() async {
    guard !hasBootstrapped else {
      return
    }
    hasBootstrapped = true
    refreshBookmarkedSessionIds()
    await bootstrap()
  }

  public func bootstrap() async {
    connectionState = .connecting
    lastError = nil

    async let daemonStatusResponse: DaemonStatusReport? = try? daemonController.daemonStatus()

    do {
      let client = try await daemonController.bootstrapClient()
      daemonStatus = await daemonStatusResponse
      await connect(using: client)
    } catch {
      daemonStatus = await daemonStatusResponse
      markConnectionOffline(error.localizedDescription)
    }
  }

  public func startDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let client = try await daemonController.startDaemonClient()
      try? await Task.sleep(for: .milliseconds(300))
      await connect(using: client)
    } catch {
      markConnectionOffline(error.localizedDescription)
    }
  }

  public func stopDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.stopDaemon()
      stopAllStreams()
      client = nil
      markConnectionOffline("Daemon stopped")
      await refreshDaemonStatus()
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
  }
}
