import Foundation
import XCTest

@testable import HarnessMonitorKit

final class MonitorPathsTests: XCTestCase {
  func testUsesXDGDataHomeWhenPresent() {
    let environment = MonitorEnvironment(
      values: ["XDG_DATA_HOME": "/tmp/harness-xdg"],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      MonitorPaths.manifestURL(using: environment).path,
      "/tmp/harness-xdg/harness/daemon/manifest.json"
    )
  }

  func testFallsBackToApplicationSupportOnMacOS() {
    let environment = MonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      MonitorPaths.authTokenURL(using: environment).path,
      "/Users/example/Library/Application Support/harness/daemon/auth-token"
    )
  }

  func testLaunchAgentLivesInUserLibraryLaunchAgents() {
    let environment = MonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      MonitorPaths.launchAgentURL(using: environment).path,
      "/Users/example/Library/LaunchAgents/io.harness.monitor.daemon.plist"
    )
  }
}

@MainActor
final class MonitorStoreActionTests: XCTestCase {
  func testCreateTaskSendsRequestAndRefreshesSession() async throws {
    let (store, client) = await makeStore()

    await store.createTask(
      title: "Ship the cockpit action surface",
      context: "Expose the cockpit mutations through the store.",
      severity: .critical,
      actor: "leader-claude"
    )

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .createTask(
          sessionID: PreviewFixtures.summary.sessionId,
          title: "Ship the cockpit action surface",
          context: "Expose the cockpit mutations through the store.",
          severity: .critical,
          actor: "leader-claude"
        )
      ]
    )
    XCTAssertEqual(
      store.selectedSession?.tasks.first(where: {
        $0.title == "Ship the cockpit action surface"
      })?.title,
      "Ship the cockpit action surface"
    )
  }

  func testAssignTaskSendsRequestAndRefreshesSession() async throws {
    let (store, client) = await makeStore()

    await store.assignTask(
      taskID: PreviewFixtures.tasks[0].taskId,
      agentID: PreviewFixtures.agents[1].agentId,
      actor: "leader-claude"
    )

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .assignTask(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: PreviewFixtures.tasks[0].taskId,
          agentID: PreviewFixtures.agents[1].agentId,
          actor: "leader-claude"
        )
      ]
    )
    XCTAssertEqual(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.assignedTo,
      PreviewFixtures.agents[1].agentId
    )
  }

  func testUpdateTaskStatusSendsRequestAndRefreshesSession() async throws {
    let (store, client) = await makeStore()

    await store.updateTaskStatus(
      taskID: PreviewFixtures.tasks[0].taskId,
      status: .done,
      note: "Validated by strict app tests.",
      actor: "worker-codex"
    )

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .updateTask(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: PreviewFixtures.tasks[0].taskId,
          status: .done,
          note: "Validated by strict app tests.",
          actor: "worker-codex"
        )
      ]
    )
    XCTAssertEqual(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.status,
      .done
    )
  }

  func testCheckpointTaskSendsRequestAndRefreshesSession() async throws {
    let (store, client) = await makeStore()

    await store.checkpointTask(
      taskID: PreviewFixtures.tasks[0].taskId,
      summary: "Cookbook lane is green.",
      progress: 88,
      actor: "worker-codex"
    )

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .checkpointTask(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: PreviewFixtures.tasks[0].taskId,
          summary: "Cookbook lane is green.",
          progress: 88,
          actor: "worker-codex"
        )
      ]
    )
    XCTAssertEqual(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.checkpointSummary?.progress,
      88
    )
  }

  func testChangeRoleSendsRequestAndRefreshesSession() async throws {
    let (store, client) = await makeStore()

    await store.changeRole(
      agentID: PreviewFixtures.agents[1].agentId,
      role: .reviewer,
      actor: "leader-claude"
    )

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .changeRole(
          sessionID: PreviewFixtures.summary.sessionId,
          agentID: PreviewFixtures.agents[1].agentId,
          role: .reviewer,
          actor: "leader-claude"
        )
      ]
    )
    XCTAssertEqual(
      store.selectedSession?.agents.first(where: {
        $0.agentId == PreviewFixtures.agents[1].agentId
      })?.role,
      .reviewer
    )
  }

  func testTransferLeaderSendsRequestAndRefreshesSession() async throws {
    let (store, client) = await makeStore()

    await store.transferLeader(
      newLeaderID: PreviewFixtures.agents[1].agentId,
      reason: "New agent has the context",
      actor: "observer-gwen"
    )

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .transferLeader(
          sessionID: PreviewFixtures.summary.sessionId,
          newLeaderID: PreviewFixtures.agents[1].agentId,
          reason: "New agent has the context",
          actor: "observer-gwen"
        )
      ]
    )
    XCTAssertEqual(store.selectedSession?.session.leaderId, PreviewFixtures.agents[1].agentId)
  }

  private func makeStore() async -> (MonitorStore, RecordingMonitorClient) {
    let client = RecordingMonitorClient()
    let daemon = RecordingDaemonController(client: client)
    let store = MonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return (store, client)
  }
}

private actor RecordingDaemonController: DaemonControlling {
  private let client: any MonitorClientProtocol

  init(client: any MonitorClientProtocol) {
    self.client = client
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
        installed: true,
        label: "io.harness.monitor.daemon",
        path: "/tmp/io.harness.monitor.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1
    )
  }

  func installLaunchAgent() async throws -> String {
    "/tmp/io.harness.monitor.daemon.plist"
  }

  func removeLaunchAgent() async throws -> String {
    "removed"
  }
}

extension RecordingMonitorClient {
  func replacing(tasks: [WorkItem]) -> SessionDetail {
    SessionDetail(
      session: updatedSession(),
      agents: detail.agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer
    )
  }

  func replacingTask(
    _ taskID: String,
    transform: (WorkItem) -> WorkItem
  ) -> SessionDetail {
    let tasks = detail.tasks.map { task in
      task.taskId == taskID ? transform(task) : task
    }
    return SessionDetail(
      session: updatedSession(),
      agents: detail.agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer
    )
  }

  func replacingAgent(
    _ agentID: String,
    transform: (AgentRegistration) -> AgentRegistration
  ) -> SessionDetail {
    let agents = detail.agents.map { agent in
      agent.agentId == agentID ? transform(agent) : agent
    }
    return SessionDetail(
      session: updatedSession(),
      agents: agents,
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer
    )
  }

  func updatedSession() -> SessionSummary {
    SessionSummary(
      projectId: detail.session.projectId,
      projectName: detail.session.projectName,
      projectDir: detail.session.projectDir,
      contextRoot: detail.session.contextRoot,
      sessionId: detail.session.sessionId,
      context: detail.session.context,
      status: detail.session.status,
      createdAt: detail.session.createdAt,
      updatedAt: "2026-03-28T14:24:00Z",
      lastActivityAt: "2026-03-28T14:24:00Z",
      leaderId: detail.session.leaderId,
      observeId: detail.session.observeId,
      metrics: detail.session.metrics
    )
  }

  func note(from request: TaskUpdateRequest) -> [TaskNote] {
    guard let note = request.note else {
      return []
    }
    return [
      TaskNote(
        timestamp: "2026-03-28T14:21:00Z",
        agentId: request.actor,
        text: note
      )
    ]
  }
}
