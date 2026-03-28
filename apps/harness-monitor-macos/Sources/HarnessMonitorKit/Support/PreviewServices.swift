import Foundation

public final class PreviewMonitorClient: MonitorClientProtocol, @unchecked Sendable {
  public init() {}

  public func health() async throws -> HealthResponse {
    HealthResponse(
      status: "ok",
      version: "14.5.0",
      pid: 4242,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-03-28T14:00:00Z",
      projectCount: 1,
      sessionCount: 1
    )
  }

  public func projects() async throws -> [ProjectSummary] {
    PreviewFixtures.projects
  }

  public func sessions() async throws -> [SessionSummary] {
    [PreviewFixtures.summary]
  }

  public func sessionDetail(id _: String) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func timeline(sessionID _: String) async throws -> [TimelineEntry] {
    PreviewFixtures.timeline
  }

  public func globalStream() -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(
        StreamEvent(
          event: "ready",
          recordedAt: "2026-03-28T14:00:00Z",
          sessionId: nil,
          payload: .object([:])
        )
      )
      continuation.finish()
    }
  }

  public func sessionStream(sessionID _: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(
        StreamEvent(
          event: "ready",
          recordedAt: "2026-03-28T14:00:00Z",
          sessionId: PreviewFixtures.summary.sessionId,
          payload: .object([:])
        )
      )
      continuation.finish()
    }
  }

  public func createTask(sessionID _: String, request _: TaskCreateRequest) async throws
    -> SessionDetail
  { PreviewFixtures.detail }

  public func assignTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskAssignRequest
  ) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func updateTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskUpdateRequest
  ) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func checkpointTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func changeRole(
    sessionID _: String,
    agentID _: String,
    request _: RoleChangeRequest
  ) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func transferLeader(
    sessionID _: String,
    request _: LeaderTransferRequest
  ) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func endSession(
    sessionID _: String,
    request _: SessionEndRequest
  ) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func sendSignal(
    sessionID _: String,
    request _: SignalSendRequest
  ) async throws -> SessionDetail {
    PreviewFixtures.detail
  }

  public func observeSession(sessionID _: String) async throws -> SessionDetail {
    PreviewFixtures.detail
  }
}

public actor PreviewDaemonController: DaemonControlling {
  private let client = PreviewMonitorClient()

  public init() {}

  public func bootstrapClient() async throws -> any MonitorClientProtocol {
    client
  }

  public func startDaemonClient() async throws -> any MonitorClientProtocol {
    client
  }

  public func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        label: "io.harness.monitor.daemon",
        path: "/Users/example/Library/LaunchAgents/io.harness.monitor.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1
    )
  }

  public func installLaunchAgent() async throws -> String {
    "/Users/example/Library/LaunchAgents/io.harness.monitor.daemon.plist"
  }

  public func removeLaunchAgent() async throws -> String {
    "removed"
  }
}
