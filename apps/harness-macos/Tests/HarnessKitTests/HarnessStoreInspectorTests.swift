import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store inspector")
struct HarnessStoreInspectorTests {
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
    #expect(!actors.isEmpty)
  }
}
