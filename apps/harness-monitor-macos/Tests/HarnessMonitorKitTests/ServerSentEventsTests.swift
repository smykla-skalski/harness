import XCTest

@testable import HarnessMonitorKit

final class ServerSentEventsTests: XCTestCase {
  func testParsesSingleEvent() {
    var parser = ServerSentEventParser()

    XCTAssertNil(parser.push(line: "event: session_updated"))
    XCTAssertNil(parser.push(line: "data: {\"event\":\"session_updated\"}"))

    let frame = parser.push(line: "")
    XCTAssertEqual(frame?.event, "session_updated")
    XCTAssertEqual(frame?.data, #"{"event":"session_updated"}"#)
  }

  func testCombinesMultilinePayloads() {
    var parser = ServerSentEventParser()

    XCTAssertNil(parser.push(line: "data: {"))
    XCTAssertNil(parser.push(line: "data: \"event\":\"ready\""))

    let frame = parser.push(line: "")
    XCTAssertEqual(frame?.data, "{\n\"event\":\"ready\"")
  }
}

final class RecordingMonitorClient: MonitorClientProtocol, @unchecked Sendable {
  enum Call: Equatable {
    case assignTask(sessionID: String, taskID: String, agentID: String, actor: String)
    case checkpointTask(
      sessionID: String,
      taskID: String,
      summary: String,
      progress: Int,
      actor: String
    )
    case changeRole(sessionID: String, agentID: String, role: SessionRole, actor: String)
    case createTask(
      sessionID: String,
      title: String,
      context: String?,
      severity: TaskSeverity,
      actor: String
    )
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

  func globalStream() -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func sessionStream(sessionID _: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    calls.append(
      .createTask(
        sessionID: sessionID,
        title: request.title,
        context: request.context,
        severity: request.severity,
        actor: request.actor
      )
    )

    let task = WorkItem(
      taskId: "task-created",
      title: request.title,
      context: request.context,
      severity: request.severity,
      status: .open,
      assignedTo: nil,
      createdAt: "2026-03-28T14:19:00Z",
      updatedAt: "2026-03-28T14:19:00Z",
      createdBy: request.actor,
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    )
    detail = replacing(tasks: detail.tasks + [task])
    return detail
  }

  func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail {
    calls.append(
      .assignTask(
        sessionID: sessionID,
        taskID: taskID,
        agentID: request.agentId,
        actor: request.actor
      )
    )
    detail = replacingTask(taskID) { task in
      WorkItem(
        taskId: task.taskId,
        title: task.title,
        context: task.context,
        severity: task.severity,
        status: .inProgress,
        assignedTo: request.agentId,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:20:00Z",
        createdBy: task.createdBy,
        notes: task.notes,
        suggestedFix: task.suggestedFix,
        source: task.source,
        blockedReason: task.blockedReason,
        completedAt: task.completedAt,
        checkpointSummary: task.checkpointSummary
      )
    }
    return detail
  }

  func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail {
    calls.append(
      .updateTask(
        sessionID: sessionID,
        taskID: taskID,
        status: request.status,
        note: request.note,
        actor: request.actor
      )
    )
    detail = replacingTask(taskID) { task in
      WorkItem(
        taskId: task.taskId,
        title: task.title,
        context: task.context,
        severity: task.severity,
        status: request.status,
        assignedTo: task.assignedTo,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:21:00Z",
        createdBy: task.createdBy,
        notes: task.notes + note(from: request),
        suggestedFix: task.suggestedFix,
        source: task.source,
        blockedReason: task.blockedReason,
        completedAt: request.status == .done ? "2026-03-28T14:21:00Z" : task.completedAt,
        checkpointSummary: task.checkpointSummary
      )
    }
    return detail
  }

  func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    calls.append(
      .checkpointTask(
        sessionID: sessionID,
        taskID: taskID,
        summary: request.summary,
        progress: request.progress,
        actor: request.actor
      )
    )
    detail = replacingTask(taskID) { task in
      WorkItem(
        taskId: task.taskId,
        title: task.title,
        context: task.context,
        severity: task.severity,
        status: task.status,
        assignedTo: task.assignedTo,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:22:00Z",
        createdBy: task.createdBy,
        notes: task.notes,
        suggestedFix: task.suggestedFix,
        source: task.source,
        blockedReason: task.blockedReason,
        completedAt: task.completedAt,
        checkpointSummary: TaskCheckpointSummary(
          checkpointId: "\(task.taskId)-cp",
          recordedAt: "2026-03-28T14:22:00Z",
          actorId: request.actor,
          summary: request.summary,
          progress: request.progress
        )
      )
    }
    return detail
  }

  func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    calls.append(
      .changeRole(
        sessionID: sessionID,
        agentID: agentID,
        role: request.role,
        actor: request.actor
      )
    )
    detail = replacingAgent(agentID) { agent in
      AgentRegistration(
        agentId: agent.agentId,
        name: agent.name,
        runtime: agent.runtime,
        role: request.role,
        capabilities: agent.capabilities,
        joinedAt: agent.joinedAt,
        updatedAt: "2026-03-28T14:23:00Z",
        status: agent.status,
        agentSessionId: agent.agentSessionId,
        lastActivityAt: agent.lastActivityAt,
        currentTaskId: agent.currentTaskId,
        runtimeCapabilities: agent.runtimeCapabilities
      )
    }
    return detail
  }

  func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    calls.append(
      .transferLeader(
        sessionID: sessionID,
        newLeaderID: request.newLeaderId,
        reason: request.reason,
        actor: request.actor
      )
    )
    detail = SessionDetail(
      session: SessionSummary(
        projectId: detail.session.projectId,
        projectName: detail.session.projectName,
        projectDir: detail.session.projectDir,
        contextRoot: detail.session.contextRoot,
        sessionId: detail.session.sessionId,
        context: detail.session.context,
        status: detail.session.status,
        createdAt: detail.session.createdAt,
        updatedAt: "2026-03-28T14:24:00Z",
        lastActivityAt: detail.session.lastActivityAt,
        leaderId: request.newLeaderId,
        observeId: detail.session.observeId,
        metrics: detail.session.metrics
      ),
      agents: detail.agents,
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer
    )
    return detail
  }

  func endSession(
    sessionID _: String,
    request _: SessionEndRequest
  ) async throws -> SessionDetail {
    detail
  }

  func sendSignal(
    sessionID _: String,
    request _: SignalSendRequest
  ) async throws -> SessionDetail {
    detail
  }

  func observeSession(sessionID _: String) async throws -> SessionDetail {
    detail
  }
}
