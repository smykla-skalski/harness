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
  public var searchText = ""
  public var sessionFilter: SessionFilter = .active
  public var sessionFocusFilter: SessionFocusFilter = .all
  public var sessionSortOrder: SessionSortOrder = .recentActivity
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
  public var showConfirmation: Bool {
    get { pendingConfirmation != nil }
    set { if !newValue { cancelConfirmation() } }
  }
  public var activeTransport: TransportKind = .httpSSE
  public var connectionMetrics: ConnectionMetrics = .initial
  public var connectionEvents: [ConnectionEvent] = []
  public var subscribedSessionIDs: Set<String> = []
  public var isShowingCachedData = false
  public var bookmarkedSessionIds: Set<String> = []
  public var navigationBackStack: [String?] = []
  public var navigationForwardStack: [String?] = []
  var connectionProbeInterval: Duration = .seconds(10)
  public var dataReceivedPulse: Bool {
    guard connectionState == .online,
      let lastMessageAt = connectionMetrics.lastMessageAt
    else {
      return false
    }

    return Date.now.timeIntervalSince(lastMessageAt) < 1.5
  }

  let daemonController: any DaemonControlling
  public let modelContext: ModelContext?
  var client: (any HarnessClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
  var connectionProbeTask: Task<Void, Never>?
  var latencySamplesMs: [Int] = []
  var trafficSampleTimes: [Date] = []
  var activeSessionLoadRequest: UInt64 = 0
  var sessionLoadSequence: UInt64 = 0
  var isNavigatingHistory = false
  private var hasBootstrapped = false

  public init(
    daemonController: any DaemonControlling,
    modelContext: ModelContext? = nil
  ) {
    self.daemonController = daemonController
    self.modelContext = modelContext
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
  }
}
