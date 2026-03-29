import XCTest

@testable import HarnessKit

@MainActor
final class HarnessStoreActionTests: XCTestCase {
  func testCreateTaskSendsRequestAndRefreshesSession() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

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
    XCTAssertEqual(store.selectedSession?.tasks.last?.title, "Ship the cockpit action surface")
    XCTAssertEqual(store.lastAction, "Create task")
  }

  func testAssignTaskSendsRequestAndRefreshesSession() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

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
    XCTAssertEqual(store.lastAction, "Assign task")
  }

  func testUpdateTaskStatusSendsRequestAndRefreshesSession() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

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
    XCTAssertEqual(store.lastAction, "Update task")
  }

  func testCheckpointTaskSendsRequestAndRefreshesSession() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

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
    XCTAssertEqual(store.lastAction, "Save checkpoint")
  }

  func testChangeRoleSendsRequestAndRefreshesSession() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

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
    XCTAssertEqual(store.lastAction, "Change role")
  }

  func testTransferLeaderSendsRequestAndRefreshesSession() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

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
    XCTAssertEqual(store.lastAction, "Transfer leader")
  }

  func testRemoveAgentSendsRequestAndRefreshesSession() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    await store.removeAgent(agentID: PreviewFixtures.agents[1].agentId, actor: "leader-claude")

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .removeAgent(
          sessionID: PreviewFixtures.summary.sessionId,
          agentID: PreviewFixtures.agents[1].agentId,
          actor: "leader-claude"
        )
      ]
    )
    XCTAssertFalse(
      store.selectedSession?.agents.contains(where: {
        $0.agentId == PreviewFixtures.agents[1].agentId
      }) ?? true
    )
    XCTAssertEqual(store.lastAction, "Remove agent")
  }

  func testObserveSelectedSessionTracksLastAction() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    await store.observeSelectedSession(actor: "observer-gwen")

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .observeSession(
          sessionID: PreviewFixtures.summary.sessionId,
          actor: "observer-gwen"
        )
      ]
    )
    XCTAssertEqual(store.lastAction, "Observe session")
  }

  func testEndSelectedSessionTracksLastActionAndStatus() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    await store.endSelectedSession(actor: "leader-claude")

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [.endSession(sessionID: PreviewFixtures.summary.sessionId, actor: "leader-claude")]
    )
    XCTAssertEqual(store.selectedSession?.session.status, .ended)
    XCTAssertEqual(store.lastAction, "End session")
  }

  func testSendSignalTracksLastAction() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    await store.sendSignal(
      agentID: PreviewFixtures.agents[0].agentId,
      command: "inject_context",
      message: "Focus on the stalled review lane.",
      actionHint: "task:review"
    )

    let calls = client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .sendSignal(
          sessionID: PreviewFixtures.summary.sessionId,
          agentID: PreviewFixtures.agents[0].agentId,
          command: "inject_context",
          actor: "leader-claude"
        )
      ]
    )
    XCTAssertEqual(store.lastAction, "Send signal")
  }

  func testDefaultActionActorFallsBackToSessionLeader() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    await store.createTask(
      title: "Use the live leader",
      context: "Default actor resolution should not send harness-app.",
      severity: .medium
    )

    XCTAssertEqual(
      client.recordedCalls(),
      [
        .createTask(
          sessionID: PreviewFixtures.summary.sessionId,
          title: "Use the live leader",
          context: "Default actor resolution should not send harness-app.",
          severity: .medium,
          actor: "leader-claude"
        )
      ]
    )
  }

  func testCreateTaskUsesScopedSessionActionLoading() async throws {
    let client = RecordingHarnessClient()
    client.configureMutationDelay(.milliseconds(150))
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let createTask = Task {
      await store.createTask(
        title: "Scoped loading",
        context: "Diagnostics refresh should not impersonate a mutation spinner.",
        severity: .low
      )
    }
    await Task.yield()

    XCTAssertTrue(store.isSessionActionInFlight)
    XCTAssertTrue(store.isBusy)
    XCTAssertFalse(store.isDaemonActionInFlight)
    XCTAssertFalse(store.isDiagnosticsRefreshInFlight)

    await createTask.value

    XCTAssertFalse(store.isSessionActionInFlight)
    XCTAssertFalse(store.isBusy)
  }
}
