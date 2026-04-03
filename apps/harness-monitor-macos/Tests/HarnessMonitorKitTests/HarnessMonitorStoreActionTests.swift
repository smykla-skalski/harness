import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store actions")
struct HarnessMonitorStoreActionTests {
  @Test("Create task sends request and refreshes the selected session")
  func createTaskSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    #expect(store.lastAction == "Create task")
  }

  @Test("Assign task sends request and refreshes the selected session")
  func assignTaskSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    #expect(store.lastAction == "Assign task")
  }

  @Test("Update task status sends request and refreshes the selected session")
  func updateTaskStatusSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    #expect(store.lastAction == "Update task")
  }

  @Test("Checkpoint task sends request and refreshes the selected session")
  func checkpointTaskSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    #expect(store.lastAction == "Save checkpoint")
  }

  @Test("Change role sends request and refreshes the selected session")
  func changeRoleSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    #expect(store.lastAction == "Change role")
  }

  @Test("Transfer leader sends request and refreshes the selected session")
  func transferLeaderSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    #expect(store.lastAction == "Transfer leader")
  }

  @Test("Remove agent sends request and refreshes the selected session")
  func removeAgentSendsRequestAndRefreshesSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

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
    let agentStillPresent = store.selectedSession?.agents.contains(where: {
      $0.agentId == PreviewFixtures.agents[1].agentId
    }) ?? true
    #expect(agentStillPresent == false)
    #expect(store.lastAction == "Remove agent")
  }

  @Test("Observe selected session tracks the last action")
  func observeSelectedSessionTracksLastAction() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    await store.observeSelectedSession(actor: "observer-gwen")

    #expect(
      client.recordedCalls()
        == [
          .observeSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "observer-gwen"
          )
        ]
    )
    #expect(store.lastAction == "Observe session")
  }

  @Test("Mutation fallback refetches only the timeline")
  func mutationFallbackRefetchesOnlyTheTimeline() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId

    let baselineHealthCalls = client.readCallCount(.health)
    let baselineDiagnosticsCalls = client.readCallCount(.diagnostics)
    let baselineProjectsCalls = client.readCallCount(.projects)
    let baselineSessionsCalls = client.readCallCount(.sessions)
    let baselineDetailCalls = client.readCallCount(.sessionDetail(sessionID))
    let baselineTimelineCalls = client.readCallCount(.timeline(sessionID))

    let created = await store.createTask(
      title: "Fallback-only task",
      context: "Verify no broad refresh happens",
      severity: .medium
    )
    #expect(created)

    try? await Task.sleep(for: .milliseconds(1_050))

    #expect(client.readCallCount(.health) == baselineHealthCalls)
    #expect(client.readCallCount(.diagnostics) == baselineDiagnosticsCalls)
    #expect(client.readCallCount(.projects) == baselineProjectsCalls)
    #expect(client.readCallCount(.sessions) == baselineSessionsCalls)
    #expect(client.readCallCount(.sessionDetail(sessionID)) == baselineDetailCalls)
    #expect(client.readCallCount(.timeline(sessionID)) == baselineTimelineCalls + 1)

    store.stopAllStreams()
  }

  @Test("End selected session tracks the last action and status")
  func endSelectedSessionTracksLastActionAndStatus() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    await store.endSelectedSession(actor: "leader-claude")

    #expect(
      client.recordedCalls()
        == [
          .endSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "leader-claude"
          )
        ]
    )
    #expect(store.selectedSession?.session.status == .ended)
    #expect(store.lastAction == "End session")
  }

  @Test("Send signal tracks the last action")
  func sendSignalTracksLastAction() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    await store.sendSignal(
      agentID: PreviewFixtures.agents[0].agentId,
      command: "inject_context",
      message: "Focus on the stalled review lane.",
      actionHint: "task:review"
    )

    #expect(
      client.recordedCalls()
        == [
          .sendSignal(
            sessionID: PreviewFixtures.summary.sessionId,
            agentID: PreviewFixtures.agents[0].agentId,
            command: "inject_context",
            actor: "leader-claude"
          )
        ]
    )
    #expect(store.lastAction == "Send signal")
  }

  @Test("Offline session actions fail in read-only mode without sending daemon mutations")
  func offlineSessionActionsFailInReadOnlyMode() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    store.connectionState = .offline("daemon down")

    let created = await store.createTask(
      title: "Should not send",
      context: "Offline mode must stay read-only",
      severity: .low
    )

    #expect(created == false)
    #expect(client.recordedCalls().isEmpty)
    #expect(store.lastError?.contains("read-only mode") == true)

    store.requestEndSelectedSessionConfirmation()
    #expect(store.pendingConfirmation == nil)
  }

  @Test("Default action actor falls back to the session leader")
  func defaultActionActorFallsBackToSessionLeader() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    await store.createTask(
      title: "Use the live leader",
      context: "Default actor resolution should not send harness-app.",
      severity: .medium
    )

    #expect(
      client.recordedCalls()
        == [
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

  @Test("Create task uses scoped session action loading")
  func createTaskUsesScopedSessionActionLoading() async {
    let client = RecordingHarnessClient()
    client.configureMutationDelay(.milliseconds(150))
    let store = await selectedStore(client: client)

    let createTask = Task {
      await store.createTask(
        title: "Scoped loading",
        context: "Diagnostics refresh should not impersonate a mutation spinner.",
        severity: .low
      )
    }
    await Task.yield()

    #expect(store.isSessionActionInFlight)
    #expect(store.isBusy)
    #expect(store.isDaemonActionInFlight == false)
    #expect(store.isDiagnosticsRefreshInFlight == false)

    _ = await createTask.value

    #expect(store.isSessionActionInFlight == false)
    #expect(store.isBusy == false)
  }

  private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return store
  }
}
