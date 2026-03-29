import Foundation

@testable import HarnessMonitorKit

extension RecordingMonitorClient {
  func health() async throws -> HealthResponse {
    HealthResponse(
      status: "ok",
      version: "14.5.0",
      pid: 111,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-03-28T14:00:00Z",
      projectCount: 1,
      sessionCount: 1
    )
  }

  func diagnostics() async throws -> DaemonDiagnosticsReport {
    DaemonDiagnosticsReport(
      health: try await health(),
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        label: "io.harness.monitor.daemon",
        path: "/tmp/io.harness.monitor.daemon.plist"
      ),
      workspace: DaemonDiagnostics(
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
          message: "daemon ready"
        )
      ),
      recentEvents: [
        DaemonAuditEvent(
          recordedAt: "2026-03-28T14:00:00Z",
          level: "info",
          message: "daemon ready"
        )
      ]
    )
  }

  func projects() async throws -> [ProjectSummary] {
    [
      ProjectSummary(
        projectId: detail.session.projectId,
        name: detail.session.projectName,
        projectDir: detail.session.projectDir,
        contextRoot: detail.session.contextRoot,
        activeSessionCount: 1,
        totalSessionCount: 1
      )
    ]
  }

  func sessions() async throws -> [SessionSummary] {
    [detail.session]
  }

  func sessionDetail(id _: String) async throws -> SessionDetail {
    detail
  }

  func timeline(sessionID _: String) async throws -> [TimelineEntry] {
    PreviewFixtures.timeline
  }

  nonisolated func globalStream() -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  nonisolated func sessionStream(sessionID _: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    calls.append(.observeSession(sessionID: sessionID, actor: request.actor))
    return detail
  }

  func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    calls.append(.endSession(sessionID: sessionID, actor: request.actor))
    detail = SessionDetail(
      session: SessionSummary(
        projectId: detail.session.projectId,
        projectName: detail.session.projectName,
        projectDir: detail.session.projectDir,
        contextRoot: detail.session.contextRoot,
        sessionId: detail.session.sessionId,
        context: detail.session.context,
        status: .ended,
        createdAt: detail.session.createdAt,
        updatedAt: "2026-03-28T14:25:00Z",
        lastActivityAt: "2026-03-28T14:25:00Z",
        leaderId: detail.session.leaderId,
        observeId: detail.session.observeId,
        pendingLeaderTransfer: detail.session.pendingLeaderTransfer,
        metrics: detail.session.metrics
      ),
      agents: detail.agents,
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer
    )
    return detail
  }

  func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    calls.append(
      .sendSignal(
        sessionID: sessionID,
        agentID: request.agentId,
        command: request.command,
        actor: request.actor
      )
    )
    return detail
  }
}
