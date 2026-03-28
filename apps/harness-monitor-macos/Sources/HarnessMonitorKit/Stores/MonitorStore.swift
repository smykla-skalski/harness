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

  public struct SessionGroup: Identifiable, Equatable {
    public let project: ProjectSummary
    public let sessions: [SessionSummary]

    public var id: String { project.id }
  }

  public var connectionState: ConnectionState = .idle
  public var daemonStatus: DaemonStatusReport?
  public var health: HealthResponse?
  public var projects: [ProjectSummary] = []
  public var sessions: [SessionSummary] = []
  public var selectedSessionID: String?
  public var selectedSession: SessionDetail?
  public var timeline: [TimelineEntry] = []
  public var inspectorSelection: InspectorSelection = .none
  public var searchText = ""
  public var sessionFilter: SessionFilter = .active
  public var isRefreshing = false
  public var isBusy = false
  public var lastAction = ""
  public var lastError: String?

  let daemonController: any DaemonControlling
  var client: (any MonitorClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
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
    isBusy = true
    defer { isBusy = false }

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
    isBusy = true
    defer { isBusy = false }

    do {
      _ = try await daemonController.installLaunchAgent()
      await refreshDaemonStatus()
      lastAction = "Install launch agent"
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func removeLaunchAgent() async {
    isBusy = true
    defer { isBusy = false }

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
    hasBootstrapped = true
    await bootstrap()
  }

  public func refresh() async {
    guard let client else {
      await bootstrap()
      return
    }
    await refresh(using: client, preserveSelection: true)
  }

  public func selectSession(_ sessionID: String?) async {
    selectedSessionID = sessionID
    inspectorSelection = .none
    guard let client, let sessionID else {
      selectedSession = nil
      timeline = []
      sessionStreamTask?.cancel()
      sessionStreamTask = nil
      return
    }

    await loadSession(using: client, sessionID: sessionID)
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

  public func observeSelectedSession(actor: String = "monitor-app") async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    isBusy = true
    defer { isBusy = false }
    lastError = nil

    do {
      _ = actor
      selectedSession = try await client.observeSession(sessionID: sessionID)
      timeline = try await client.timeline(sessionID: sessionID)
      lastAction = "Observe session"
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func endSelectedSession(actor: String = "monitor-app") async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    isBusy = true
    defer { isBusy = false }
    lastError = nil

    do {
      selectedSession = try await client.endSession(
        sessionID: sessionID,
        request: SessionEndRequest(actor: actor)
      )
      timeline = try await client.timeline(sessionID: sessionID)
      await refresh(using: client, preserveSelection: true)
      lastAction = "End session"
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func sendSignal(
    agentID: String,
    command: String,
    message: String,
    actionHint: String?,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    isBusy = true
    defer { isBusy = false }
    lastError = nil

    do {
      selectedSession = try await client.sendSignal(
        sessionID: sessionID,
        request: SignalSendRequest(
          actor: actor,
          agentId: agentID,
          command: command,
          message: message,
          actionHint: actionHint
        )
      )
      timeline = try await client.timeline(sessionID: sessionID)
      lastAction = "Send signal"
    } catch {
      lastError = error.localizedDescription
    }
  }
}
