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
    case removeLaunchAgent
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
  public final class SessionIndexSlice {
    public var projects: [ProjectSummary] = [] {
      didSet { refreshDerivedStateIfNeeded(oldValue != projects) }
    }
    public var sessions: [SessionSummary] = [] {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessions) }
    }
    public var searchText = "" {
      didSet { refreshDerivedStateIfNeeded(oldValue != searchText) }
    }
    public var sessionFilter: SessionFilter = .active {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessionFilter) }
    }
    public var sessionFocusFilter: SessionFocusFilter = .all {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessionFocusFilter) }
    }
    public var sessionSortOrder: SessionSortOrder = .recentActivity {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessionSortOrder) }
    }
    public private(set) var groupedSessions: [SessionGroup] = []
    public private(set) var filteredSessionCount = 0
    public private(set) var totalOpenWorkCount = 0
    public private(set) var totalBlockedCount = 0
    public private(set) var sessionSummariesByID: [String: SessionSummary] = [:]

    private var suppressDerivedStateRefresh = false

    public init() {}

    public func replaceSnapshot(
      projects: [ProjectSummary],
      sessions: [SessionSummary]
    ) {
      guard self.projects != projects || self.sessions != sessions else {
        return
      }

      suppressDerivedStateRefresh = true
      self.projects = projects
      self.sessions = sessions
      suppressDerivedStateRefresh = false
      rebuildDerivedState()
    }

    public func applySessionSummary(_ summary: SessionSummary) {
      var updated = sessions
      if let index = updated.firstIndex(where: { $0.sessionId == summary.sessionId }) {
        guard updated[index] != summary else {
          return
        }
        updated[index] = summary
      } else {
        updated.append(summary)
      }
      sessions = updated
    }

    public func sessionSummary(for sessionID: String?) -> SessionSummary? {
      guard let sessionID else {
        return nil
      }
      return sessionSummariesByID[sessionID]
    }

    private func refreshDerivedStateIfNeeded(_ changed: Bool) {
      guard changed, !suppressDerivedStateRefresh else {
        return
      }
      rebuildDerivedState()
    }

    private func rebuildDerivedState() {
      totalOpenWorkCount = sessions.reduce(0) { $0 + $1.metrics.openTaskCount }
      totalBlockedCount = sessions.reduce(0) { $0 + $1.metrics.blockedTaskCount }
      sessionSummariesByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })

      let filteredSessions = sessions.filter(matchesCurrentFilters)
      filteredSessionCount = filteredSessions.count
      let sessionsByProject = Dictionary(grouping: filteredSessions, by: \.projectId)

      groupedSessions = projects.compactMap { project in
        guard let sessions = sessionsByProject[project.projectId], !sessions.isEmpty else {
          return nil
        }
        return SessionGroup(
          project: project,
          sessions: sessions.sorted(by: sessionSortOrder.compare)
        )
      }
    }

    private func matchesCurrentFilters(_ summary: SessionSummary) -> Bool {
      sessionFilter.includes(summary.status)
        && sessionFocusFilter.includes(summary)
        && searchMatches(summary)
    }

    private func searchMatches(_ summary: SessionSummary) -> Bool {
      let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !needle.isEmpty else {
        return true
      }

      let haystack = [
        summary.projectName,
        summary.projectId,
        summary.sessionId,
        summary.context,
        summary.projectDir ?? "",
        summary.contextRoot,
        summary.leaderId ?? "",
        summary.observeId ?? "",
        summary.status.rawValue,
      ].joined(separator: " ")

      return needle
        .split(whereSeparator: \.isWhitespace)
        .allSatisfy { haystack.localizedStandardContains($0) }
    }
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
