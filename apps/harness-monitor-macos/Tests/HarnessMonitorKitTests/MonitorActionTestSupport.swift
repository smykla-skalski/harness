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
    case observeSession(sessionID: String)
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

  var calls: [Call] = []
  var detail: SessionDetail

  init(detail: SessionDetail = PreviewFixtures.detail) {
    self.detail = detail
  }

  func recordedCalls() -> [Call] {
    calls
  }
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
