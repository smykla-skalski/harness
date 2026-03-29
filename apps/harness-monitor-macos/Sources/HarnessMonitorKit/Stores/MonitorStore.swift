import Foundation
import Observation

@MainActor
@Observable
public final class MonitorStore {
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
    case removeLaunchAgent
  }

  public struct SessionGroup: Identifiable, Equatable {
    public let project: ProjectSummary
    public let sessions: [SessionSummary]

    public var id: String { project.id }
  }

  public var connectionState: ConnectionState = .idle
  public var daemonStatus: DaemonStatusReport?
  public var diagnostics: DaemonDiagnosticsReport?
  public var health: HealthResponse?
  public var projects: [ProjectSummary] = []
  public var sessions: [SessionSummary] = []
  public var selectedSessionID: String?
  public var selectedSession: SessionDetail?
  public var timeline: [TimelineEntry] = []
  public var inspectorSelection: InspectorSelection = .none
  public var actionActorID: String?
  public var searchText = "" {
    didSet {
      if searchText != oldValue {
        selectedSavedSearchID = nil
      }
    }
  }
  public var sessionFilter: SessionFilter = .active {
    didSet {
      if sessionFilter != oldValue {
        selectedSavedSearchID = nil
      }
    }
  }
  public var sessionFocusFilter: SessionFocusFilter = .all {
    didSet {
      if sessionFocusFilter != oldValue {
        selectedSavedSearchID = nil
      }
    }
  }
  public var selectedSavedSearchID: String?
  public var isRefreshing = false
  public var isDiagnosticsRefreshInFlight = false
  public var isDaemonActionInFlight = false
  public var isSelectionLoading = false
  public var isSessionActionInFlight = false
  public var isBusy: Bool {
    isDaemonActionInFlight || isSessionActionInFlight
  }
  public var lastAction = ""
  public var lastError: String?
  public var pendingConfirmation: PendingConfirmation?
  public var activeTransport: TransportKind = .httpSSE
  public var connectionMetrics: ConnectionMetrics = .initial
  public var connectionEvents: [ConnectionEvent] = []
  public var subscribedSessionIDs: Set<String> = []
  public var dataReceivedPulse: Bool {
    guard connectionState == .online,
      let lastMessageAt = connectionMetrics.lastMessageAt
    else {
      return false
    }

    return Date().timeIntervalSince(lastMessageAt) < 1.5
  }

  let daemonController: any DaemonControlling
  var client: (any MonitorClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
  private var activeSessionLoadRequest: UInt64 = 0
  private var sessionLoadSequence: UInt64 = 0
  private var hasBootstrapped = false

  public init(daemonController: any DaemonControlling) {
    self.daemonController = daemonController
  }

  public func bootstrapIfNeeded() async {
    guard !hasBootstrapped else {
      return
    }
    hasBootstrapped = true
    await bootstrap()
  }

  public func bootstrap() async {
    connectionState = .connecting
    lastError = nil

    do {
      daemonStatus = try await daemonController.daemonStatus()
    } catch {
      daemonStatus = nil
    }

    do {
      let client = try await daemonController.bootstrapClient()
      await connect(using: client)
    } catch {
      connectionState = .offline(error.localizedDescription)
      lastError = error.localizedDescription
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
      connectionState = .offline(error.localizedDescription)
      lastError = error.localizedDescription
    }
  }

  public func installLaunchAgent() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.installLaunchAgent()
      await refreshDaemonStatus()
      lastAction = "Install launch agent"
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
      lastAction = "Remove launch agent"
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
    globalStreamTask?.cancel()
    sessionStreamTask?.cancel()
    globalStreamTask = nil
    sessionStreamTask = nil
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
      diagnostics = try await client.diagnostics()
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
  }

  public func primeSessionSelection(_ sessionID: String?) {
    selectedSessionID = sessionID
    inspectorSelection = .none
    lastError = nil

    guard let sessionID else {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
      selectedSession = nil
      timeline = []
      subscribedSessionIDs.removeAll()
      sessionStreamTask?.cancel()
      sessionStreamTask = nil
      return
    }

    guard selectedSession?.session.sessionId != sessionID else {
      return
    }

    isSelectionLoading = true
    selectedSession = nil
    timeline = []
  }

  public func selectSession(_ sessionID: String?) async {
    primeSessionSelection(sessionID)
    guard let client, let sessionID else {
      sessionStreamTask?.cancel()
      sessionStreamTask = nil
      return
    }

    let requestID = beginSessionLoad()
    await loadSession(using: client, sessionID: sessionID, requestID: requestID)
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
      return
    }
    startSessionStream(using: client, sessionID: sessionID)
  }

  public func inspect(taskID: String) {
    inspectorSelection = .task(taskID)
  }

  public func inspect(agentID: String) {
    inspectorSelection = .agent(agentID)
  }

  public func inspect(signalID: String) {
    inspectorSelection = .signal(signalID)
  }

  public func inspectObserver() {
    inspectorSelection = .observer
  }

  func synchronizeActionActor() {
    let available = availableActionActors
    if available.contains(where: { $0.agentId == actionActorID }) {
      return
    }
    actionActorID = selectedSession?.session.leaderId ?? available.first?.agentId
  }

  func resolvedActionActor() -> String? {
    if let actionActorID, !actionActorID.isEmpty {
      return actionActorID
    }
    if let leaderID = selectedSession?.session.leaderId, !leaderID.isEmpty {
      return leaderID
    }
    return availableActionActors.first?.agentId
  }

  func beginSessionLoad() -> UInt64 {
    sessionLoadSequence &+= 1
    activeSessionLoadRequest = sessionLoadSequence
    isSelectionLoading = true
    return sessionLoadSequence
  }

  func completeSessionLoad(_ requestID: UInt64) {
    guard activeSessionLoadRequest == requestID else {
      return
    }
    isSelectionLoading = false
  }

  func isCurrentSessionLoad(_ requestID: UInt64, sessionID: String) -> Bool {
    activeSessionLoadRequest == requestID && selectedSessionID == sessionID
  }
}
