import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store actions")
struct HarnessMonitorStoreActionTests {
  @Test("Create task sends request and refreshes the selected session")
  func createTaskSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.createTask(
      title: "Ship the cockpit action surface",
      context: "Expose the cockpit mutations through the store.",
      severity: .critical,
      actor: "leader-claude"
    )

    #expect(
      client.recordedCalls()
        == [
          .createTask(
            sessionID: PreviewFixtures.summary.sessionId,
            title: "Ship the cockpit action surface",
            context: "Expose the cockpit mutations through the store.",
            severity: .critical,
            actor: "leader-claude"
          )
        ]
    )
    #expect(store.selectedSession?.tasks.last?.title == "Ship the cockpit action surface")
    #expect(store.currentSuccessFeedbackMessage == "Create task")
  }

  @Test("Create task can target a session window without global selection")
  func createTaskCanTargetSessionWindowWithoutGlobalSelection() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.createTask(
      title: "Window scoped task",
      context: nil,
      severity: .medium,
      sessionID: PreviewFixtures.summary.sessionId,
      actor: "leader-claude"
    )

    #expect(success)
    #expect(
      client.recordedCalls()
        == [
          .createTask(
            sessionID: PreviewFixtures.summary.sessionId,
            title: "Window scoped task",
            context: nil,
            severity: .medium,
            actor: "leader-claude"
          )
        ]
    )
    #expect(store.selectedSession == nil)
  }

  @Test("Assign task sends request and refreshes the selected session")
  func assignTaskSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.assignTask(
      taskID: PreviewFixtures.tasks[0].taskId,
      agentID: PreviewFixtures.agents[1].agentId,
      actor: "leader-claude"
    )

    #expect(
      client.recordedCalls()
        == [
          .assignTask(
            sessionID: PreviewFixtures.summary.sessionId,
            taskID: PreviewFixtures.tasks[0].taskId,
            agentID: PreviewFixtures.agents[1].agentId,
            actor: "leader-claude"
          )
        ]
    )
    #expect(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.assignedTo == PreviewFixtures.agents[1].agentId
    )
    #expect(store.currentSuccessFeedbackMessage == "Assign task")
  }

  @Test("Drop task sends target request and refreshes the selected session")
  func dropTaskSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.dropTask(
      taskID: PreviewFixtures.tasks[0].taskId,
      target: .agent(agentId: PreviewFixtures.agents[1].agentId),
      actor: "leader-claude"
    )

    #expect(
      client.recordedCalls()
        == [
          .dropTask(
            sessionID: PreviewFixtures.summary.sessionId,
            taskID: PreviewFixtures.tasks[0].taskId,
            target: .agent(agentId: PreviewFixtures.agents[1].agentId),
            queuePolicy: .locked,
            actor: "leader-claude"
          )
        ]
    )
    #expect(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.assignedTo == PreviewFixtures.agents[1].agentId
    )
    #expect(store.currentSuccessFeedbackMessage == "Drop task")
  }

  @Test("Update task queue policy sends request and refreshes the selected session")
  func updateTaskQueuePolicySendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.updateTaskQueuePolicy(
      taskID: PreviewFixtures.tasks[0].taskId,
      queuePolicy: .reassignWhenFree,
      actor: "leader-claude"
    )

    #expect(
      client.recordedCalls()
        == [
          .updateTaskQueuePolicy(
            sessionID: PreviewFixtures.summary.sessionId,
            taskID: PreviewFixtures.tasks[0].taskId,
            queuePolicy: .reassignWhenFree,
            actor: "leader-claude"
          )
        ]
    )
    #expect(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.queuePolicy == .reassignWhenFree
    )
    #expect(store.currentSuccessFeedbackMessage == "Update task queue")
  }

  @Test("Update task status sends request and refreshes the selected session")
  func updateTaskStatusSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.updateTaskStatus(
      taskID: PreviewFixtures.tasks[0].taskId,
      status: .done,
      note: "Validated by strict app tests.",
      actor: "worker-codex"
    )

    #expect(
      client.recordedCalls()
        == [
          .updateTask(
            sessionID: PreviewFixtures.summary.sessionId,
            taskID: PreviewFixtures.tasks[0].taskId,
            status: .done,
            note: "Validated by strict app tests.",
            actor: "worker-codex"
          )
        ]
    )
    #expect(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.status == .done
    )
    #expect(store.currentSuccessFeedbackMessage == "Update task")
  }

  @Test("Checkpoint task sends request and refreshes the selected session")
  func checkpointTaskSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.checkpointTask(
      taskID: PreviewFixtures.tasks[0].taskId,
      summary: "Cookbook lane is green.",
      progress: 88,
      actor: "worker-codex"
    )

    #expect(
      client.recordedCalls()
        == [
          .checkpointTask(
            sessionID: PreviewFixtures.summary.sessionId,
            taskID: PreviewFixtures.tasks[0].taskId,
            summary: "Cookbook lane is green.",
            progress: 88,
            actor: "worker-codex"
          )
        ]
    )
    #expect(
      store.selectedSession?.tasks.first(where: {
        $0.taskId == PreviewFixtures.tasks[0].taskId
      })?.checkpointSummary?.progress == 88
    )
    #expect(store.currentSuccessFeedbackMessage == "Save checkpoint")
  }

  @Test("Change role sends request and refreshes the selected session")
  func changeRoleSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.changeRole(
      agentID: PreviewFixtures.agents[1].agentId,
      role: .reviewer,
      actor: "leader-claude"
    )

    #expect(
      client.recordedCalls()
        == [
          .changeRole(
            sessionID: PreviewFixtures.summary.sessionId,
            agentID: PreviewFixtures.agents[1].agentId,
            role: .reviewer,
            actor: "leader-claude"
          )
        ]
    )
    #expect(
      store.selectedSession?.agents.first(where: {
        $0.agentId == PreviewFixtures.agents[1].agentId
      })?.role == .reviewer
    )
    #expect(store.currentSuccessFeedbackMessage == "Change role")
  }

  @Test("Transfer leader sends request and refreshes the selected session")
  func transferLeaderSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.transferLeader(
      newLeaderID: PreviewFixtures.agents[1].agentId,
      reason: "New agent has the context",
      actor: "observer-gwen"
    )

    #expect(
      client.recordedCalls()
        == [
          .transferLeader(
            sessionID: PreviewFixtures.summary.sessionId,
            newLeaderID: PreviewFixtures.agents[1].agentId,
            reason: "New agent has the context",
            actor: "observer-gwen"
          )
        ]
    )
    #expect(store.selectedSession?.session.leaderId == PreviewFixtures.agents[1].agentId)
    #expect(store.currentSuccessFeedbackMessage == "Transfer leader")
  }

  @Test("Remove agent sends request and refreshes the selected session")
  func removeAgentSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.removeAgent(agentID: PreviewFixtures.agents[1].agentId, actor: "leader-claude")

    #expect(
      client.recordedCalls()
        == [
          .removeAgent(
            sessionID: PreviewFixtures.summary.sessionId,
            agentID: PreviewFixtures.agents[1].agentId,
            actor: "leader-claude"
          )
        ]
    )
    let agentStillPresent =
      store.selectedSession?.agents.contains(where: {
        $0.agentId == PreviewFixtures.agents[1].agentId
      }) ?? true
    #expect(agentStillPresent == false)
    #expect(store.currentSuccessFeedbackMessage == "Remove agent")
  }

  @Test("Typed session-agent client helpers preserve the session-agent identity class")
  func typedSessionAgentClientHelpersPreserveIdentityClass() async throws {
    let client = RecordingHarnessClient()
    let sessionID = HarnessSessionID(rawValue: PreviewFixtures.summary.sessionId)
    let sessionAgentID = SessionAgentID(rawValue: PreviewFixtures.agents[1].agentId)

    _ = try await client.changeRole(
      sessionID: sessionID,
      sessionAgentID: sessionAgentID,
      request: RoleChangeRequest(actor: "leader-claude", role: .reviewer)
    )
    _ = try await client.removeAgent(
      sessionID: sessionID,
      sessionAgentID: sessionAgentID,
      request: AgentRemoveRequest(actor: "leader-claude")
    )

    #expect(
      client.recordedCalls()
        == [
          .changeRole(
            sessionID: sessionID.rawValue,
            agentID: sessionAgentID.rawValue,
            role: .reviewer,
            actor: "leader-claude"
          ),
          .removeAgent(
            sessionID: sessionID.rawValue,
            agentID: sessionAgentID.rawValue,
            actor: "leader-claude"
          ),
        ]
    )
  }

}
