import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func transportLatencyMs() async throws -> Int? {
    recordReadCall(.transportLatency)
    return configuredTransportLatencyMs()
  }

  func health() async throws -> HealthResponse {
    recordReadCall(.health)
    try await sleepIfNeeded(configuredHealthDelay())
    return HealthResponse(
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
    recordReadCall(.diagnostics)
    try await sleepIfNeeded(configuredDiagnosticsDelay())
    return DaemonDiagnosticsReport(
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
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: "running",
        pid: 4_242,
        lastExitStatus: 0
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

  func stopDaemon() async throws -> DaemonControlResponse {
    DaemonControlResponse(status: "stopping")
  }

  func projects() async throws -> [ProjectSummary] {
    recordReadCall(.projects)
    return [
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
    recordReadCall(.sessions)
    return configuredSessions() ?? [detail.session]
  }

  func sessionDetail(id: String) async throws -> SessionDetail {
    recordReadCall(.sessionDetail(id))
    try await sleepIfNeeded(configuredDetailDelay(for: id))
    return configuredSessionDetail(id: id) ?? detail
  }

  func timeline(sessionID: String) async throws -> [TimelineEntry] {
    recordReadCall(.timeline(sessionID))
    try await sleepIfNeeded(configuredTimelineDelay(for: sessionID))
    return configuredTimeline(for: sessionID) ?? PreviewFixtures.timeline
  }

  nonisolated func globalStream() -> AsyncThrowingStream<DaemonPushEvent, Error> {
    makeStream(
      events: configuredGlobalStreamEvents(),
      error: configuredGlobalStreamError()
    )
  }

  nonisolated func sessionStream(sessionID: String) -> AsyncThrowingStream<DaemonPushEvent, Error> {
    makeStream(
      events: configuredSessionStreamEvents(for: sessionID),
      error: configuredSessionStreamError(for: sessionID)
    )
  }

  func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(.observeSession(sessionID: sessionID, actor: request.actor))
    return detail
  }

  func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
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
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
    return detail
  }

  func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
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

  func sleepIfNeeded(_ delay: Duration?) async throws {
    guard let delay else {
      return
    }
    try await Task.sleep(for: delay)
  }

  nonisolated private func makeStream(
    events: [DaemonPushEvent],
    error: (any Error)?
  ) -> AsyncThrowingStream<DaemonPushEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      if let error {
        continuation.finish(throwing: error)
      } else {
        continuation.finish()
      }
    }
  }
}
