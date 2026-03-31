import Observation
import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store navigation history")
struct HarnessStoreNavigationTests {

  // MARK: - Direct selectSession path (proves store logic)

  @Test("Selecting session from dashboard pushes nil to back stack")
  func selectFromDashboard() async {
    let store = await makeNavigationStore()

    await store.selectSession("sess-a")
    #expect(store.navigationBackStack.count == 1)
    #expect(store.navigationBackStack.first == nil as String?)
  }

  @Test("Selecting two sessions populates the back stack")
  func selectTwoSessions() async {
    let store = await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("Navigate back restores previous session and populates forward stack")
  func navigateBack() async {
    let store = await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()

    #expect(store.selectedSessionID == "sess-a")
    #expect(store.navigationBackStack == [nil])
    #expect(store.navigationForwardStack == ["sess-b"] as [String?])
  }

  @Test("Navigate back to dashboard clears selection")
  func navigateBackToDashboard() async {
    let store = await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.navigateBack()

    #expect(store.selectedSessionID == nil)
    #expect(store.navigationBackStack.isEmpty)
    #expect(store.navigationForwardStack == ["sess-a"] as [String?])
  }

  @Test("Navigate forward after back restores forward session")
  func navigateForward() async {
    let store = await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()
    await store.navigateForward()

    #expect(store.selectedSessionID == "sess-b")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("New selection after back clears forward stack")
  func newSelectionClearsForward() async {
    let store = await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()
    await store.selectSession("sess-c")

    #expect(store.selectedSessionID == "sess-c")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("Sidebar flow: primeSessionSelection then selectSession records history")
  func sidebarPrimeThenSelect() async {
    let store = await makeNavigationStore()

    store.primeSessionSelection("sess-a")
    await store.selectSession("sess-a")
    #expect(store.selectedSessionID == "sess-a")
    #expect(store.navigationBackStack.count == 1)

    store.primeSessionSelection("sess-b")
    await store.selectSession("sess-b")
    #expect(store.selectedSessionID == "sess-b")
    #expect(
      store.navigationBackStack.contains("sess-a"),
      "primeSessionSelection before selectSession must not prevent history recording"
    )
  }

  @Test("Observable tracking: back stack mutation is observable")
  func backStackMutationIsObservable() async {
    let store = await makeNavigationStore()

    await confirmation("back stack change observed") { confirm in
      withObservationTracking {
        _ = store.navigationBackStack
      } onChange: {
        confirm()
      }

      await store.selectSession("sess-a")
    }

    #expect(!store.navigationBackStack.isEmpty)
  }

  // MARK: - Fixtures

  private func makeNavigationStore() async -> HarnessStore {
    let summaries = ["sess-a", "sess-b", "sess-c"].map { id in
      makeSession(
        SessionFixture(
          sessionId: id,
          context: "Session \(id)",
          status: .active,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        )
      )
    }
    let details = Dictionary(
      uniqueKeysWithValues: summaries.map { summary in
        (summary.sessionId, makeSessionDetail(
          summary: summary,
          workerID: "worker-\(summary.sessionId)",
          workerName: "Worker \(summary.sessionId)"
        ))
      }
    )
    let client = RecordingHarnessClient(detail: details.values.first!)
    client.configureSessions(summaries: summaries, detailsByID: details)
    return await makeBootstrappedStore(client: client)
  }
}
