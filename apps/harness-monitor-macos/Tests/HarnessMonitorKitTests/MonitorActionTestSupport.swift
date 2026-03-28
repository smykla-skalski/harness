import Foundation

@testable import HarnessMonitorKit

actor RecordingDaemonController: DaemonControlling {
  private let client: any MonitorClientProtocol
  private var launchAgentInstalled: Bool
  private var lastEventMessage = "daemon ready"

  init(
    client: any MonitorClientProtocol = PreviewMonitorClient(),
    launchAgentInstalled: Bool = true
  ) {
    self.client = client
    self.launchAgentInstalled = launchAgentInstalled
  }

  func bootstrapClient() async throws -> any MonitorClientProtocol {
    client
  }

  func startDaemonClient() async throws -> any MonitorClientProtocol {
    client
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: launchAgentInstalled,
        label: "io.harness.monitor.daemon",
        path: "/tmp/io.harness.monitor.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        cacheRoot: "/tmp/harness/daemon/cache/projects",
        cacheEntryCount: 2,
        lastEvent: DaemonAuditEvent(
          recordedAt: "2026-03-28T14:00:00Z",
          level: "info",
          message: lastEventMessage
        )
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    launchAgentInstalled = true
    lastEventMessage = "launch agent installed"
    return "/tmp/io.harness.monitor.daemon.plist"
  }

  func removeLaunchAgent() async throws -> String {
    launchAgentInstalled = false
    lastEventMessage = "launch agent removed"
    return "removed"
  }
}

final class RecordingMonitorClient: MonitorClientProtocol, @unchecked Sendable {
  enum Call: Equatable {
    case assignTask(sessionID: String, taskID: String, agentID: String, actor: String)
    case changeRole(sessionID: String, agentID: String, role: SessionRole, actor: String)
    case checkpointTask(
      sessionID: String,
      taskID: String,
      summary: String,
      progress: Int,
      actor: String
    )
    case createTask(
      sessionID: String,
      title: String,
      context: String?,
      severity: TaskSeverity,
      actor: String
    )
    case endSession(sessionID: String, actor: String)
    case observeSession(sessionID: String, actor: String)
    case sendSignal(sessionID: String, agentID: String, command: String, actor: String)
    case transferLeader(sessionID: String, newLeaderID: String, reason: String?, actor: String)
    case updateTask(
      sessionID: String,
      taskID: String,
      status: TaskStatus,
      note: String?,
      actor: String
    )
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  private var _detail: SessionDetail

  var calls: [Call] {
    get { lock.withLock { _calls } }
    set { lock.withLock { _calls = newValue } }
  }

  var detail: SessionDetail {
    get { lock.withLock { _detail } }
    set { lock.withLock { _detail = newValue } }
  }

  init(detail: SessionDetail = PreviewFixtures.detail) {
    self._detail = detail
  }

  func recordedCalls() -> [Call] {
    calls
  }
}

actor FailingDaemonController: DaemonControlling {
  private let bootstrapError: (any Error)?
  private let actionError: (any Error)?

  init(
    bootstrapError: (any Error)? = nil,
    actionError: (any Error)? = nil
  ) {
    self.bootstrapError = bootstrapError
    self.actionError = actionError
  }

  func bootstrapClient() async throws -> any MonitorClientProtocol {
    if let bootstrapError {
      throw bootstrapError
    }
    return PreviewMonitorClient()
  }

  func startDaemonClient() async throws -> any MonitorClientProtocol {
    if let bootstrapError {
      throw bootstrapError
    }
    return PreviewMonitorClient()
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    throw DaemonControlError.manifestMissing
  }

  func installLaunchAgent() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "/tmp/test.plist"
  }

  func removeLaunchAgent() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "removed"
  }
}

final class FailingMonitorClient: MonitorClientProtocol, @unchecked Sendable {
  private let error: any Error

  init(error: any Error = MonitorAPIError.server(code: 500, message: "internal error")) {
    self.error = error
  }

  func health() async throws -> HealthResponse { throw error }
  func diagnostics() async throws -> DaemonDiagnosticsReport { throw error }
  func projects() async throws -> [ProjectSummary] { throw error }
  func sessions() async throws -> [SessionSummary] { throw error }
  func sessionDetail(id _: String) async throws -> SessionDetail { throw error }
  func timeline(sessionID _: String) async throws -> [TimelineEntry] { throw error }

  nonisolated func globalStream() -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: self.error) }
  }

  nonisolated func sessionStream(sessionID _: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: self.error) }
  }

  func createTask(sessionID _: String, request _: TaskCreateRequest) async throws -> SessionDetail {
    throw error
  }

  func assignTask(
    sessionID _: String, taskID _: String, request _: TaskAssignRequest
  ) async throws -> SessionDetail { throw error }

  func updateTask(
    sessionID _: String, taskID _: String, request _: TaskUpdateRequest
  ) async throws -> SessionDetail { throw error }

  func checkpointTask(
    sessionID _: String, taskID _: String, request _: TaskCheckpointRequest
  ) async throws -> SessionDetail { throw error }

  func changeRole(
    sessionID _: String, agentID _: String, request _: RoleChangeRequest
  ) async throws -> SessionDetail { throw error }

  func transferLeader(
    sessionID _: String, request _: LeaderTransferRequest
  ) async throws -> SessionDetail { throw error }

  func endSession(
    sessionID _: String, request _: SessionEndRequest
  ) async throws -> SessionDetail { throw error }

  func sendSignal(
    sessionID _: String, request _: SignalSendRequest
  ) async throws -> SessionDetail { throw error }

  func observeSession(
    sessionID _: String, request _: ObserveSessionRequest
  ) async throws -> SessionDetail { throw error }
}

@MainActor
func makeBootstrappedStore(
  client: any MonitorClientProtocol = RecordingMonitorClient()
) async -> MonitorStore {
  let daemon = RecordingDaemonController(client: client)
  let store = MonitorStore(daemonController: daemon)
  await store.bootstrap()
  return store
}
