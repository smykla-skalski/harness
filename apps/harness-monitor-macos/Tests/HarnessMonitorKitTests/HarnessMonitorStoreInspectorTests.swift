import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store inspector")
struct HarnessMonitorStoreInspectorTests {
  @Test("Inspect agent sets inspector selection to agent")
  func inspectAgentSetsSelection() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.inspect(agentID: PreviewFixtures.agents[1].agentId)

    #expect(store.inspectorSelection == .agent(PreviewFixtures.agents[1].agentId))
  }

  @Test("Inspect signal sets inspector selection to signal")
  func inspectSignalSetsSelection() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.inspect(signalID: PreviewFixtures.signals[0].signal.signalId)

    #expect(
      store.inspectorSelection == .signal(PreviewFixtures.signals[0].signal.signalId)
    )
  }

  @Test("Inspect observer sets inspector selection to observer")
  func inspectObserverSetsSelection() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.inspectObserver()

    #expect(store.inspectorSelection == .observer)
  }

  @Test("Selected agent resolves from loaded session detail")
  func selectedAgentResolvesFromDetail() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.inspect(agentID: PreviewFixtures.agents[1].agentId)

    let agent = store.selectedAgent
    #expect(agent?.agentId == PreviewFixtures.agents[1].agentId)
    #expect(agent?.runtime == PreviewFixtures.agents[1].runtime)
  }

  @Test("Selected agent returns nil when inspector is not on an agent")
  func selectedAgentReturnsNilForNonAgentSelection() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.inspect(taskID: PreviewFixtures.tasks[0].taskId)

    #expect(store.selectedAgent == nil)
  }

  @Test("Selected signal resolves from loaded session detail")
  func selectedSignalResolvesFromDetail() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.inspect(signalID: PreviewFixtures.signals[0].signal.signalId)

    let signal = store.selectedSignal
    #expect(signal?.signal.signalId == PreviewFixtures.signals[0].signal.signalId)
  }

  @Test("Selected signal returns nil when inspector is not on a signal")
  func selectedSignalReturnsNilForNonSignalSelection() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.inspectObserver()

    #expect(store.selectedSignal == nil)
  }

  @Test("Available action actors filters to active agents only")
  func availableActionActorsFiltersToActive() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let actors = store.availableActionActors
    #expect(actors.allSatisfy { $0.status == .active })
    #expect(actors.isEmpty == false)
  }

  @Test("Inspector action context keeps the selected leader available when disconnected")
  func actionContextKeepsDisconnectedLeaderAvailable() async {
    let leaderID = "leader-disconnected"
    let workerID = "worker-connected"
    let summary = makeSession(
      .init(
        sessionId: "sess-disconnected-leader",
        context: "Disconnected leader fallback",
        status: .active,
        leaderId: leaderID,
        observeId: "observe-disconnected-leader",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    let detail = SessionDetail(
      session: summary,
      agents: [
        AgentRegistration(
          agentId: leaderID,
          name: "Disconnected Leader",
          runtime: "claude",
          role: .leader,
          capabilities: ["general"],
          joinedAt: summary.createdAt,
          updatedAt: summary.updatedAt,
          status: .disconnected,
          agentSessionId: "\(leaderID)-session",
          lastActivityAt: summary.lastActivityAt,
          currentTaskId: nil,
          runtimeCapabilities: capabilities
        ),
        AgentRegistration(
          agentId: workerID,
          name: "Connected Worker",
          runtime: "codex",
          role: .worker,
          capabilities: ["general"],
          joinedAt: summary.createdAt,
          updatedAt: summary.updatedAt,
          status: .active,
          agentSessionId: "\(workerID)-session",
          lastActivityAt: summary.lastActivityAt,
          currentTaskId: nil,
          runtimeCapabilities: capabilities
        ),
      ],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)

    guard let actionContext = store.inspectorUI.actionContext else {
      Issue.record("Expected inspector action context for the selected session")
      return
    }

    #expect(actionContext.selectedActionActorID == leaderID)
    #expect(actionContext.actionActorOptions.contains { $0.agentId == workerID })
    #expect(
      actionContext.actionActorOptions.contains { actor in
        actor.agentId == leaderID && actor.status == .disconnected
      })
  }

  @Test("Inspector primary content ignores filter churn when selection is unchanged")
  func inspectorPrimaryContentIgnoresFilterChurn() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let didChange = await didInvalidate(
      { store.inspectorUI.primaryContent },
      after: {
        store.searchText = "preview"
      }
    )

    #expect(didChange == false)
  }

  @Test("Inspector primary content tracks inspector selection changes")
  func inspectorPrimaryContentTracksInspectorSelectionChanges() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let didChange = await didInvalidate(
      { store.inspectorUI.primaryContent },
      after: {
        store.inspect(agentID: PreviewFixtures.agents[1].agentId)
      }
    )

    #expect(didChange)
    switch store.inspectorUI.primaryContent {
    case .agent(let selection):
      #expect(selection.agent.agentId == PreviewFixtures.agents[1].agentId)
    default:
      Issue.record("Expected inspector primary content to resolve the selected agent")
    }
  }
}
