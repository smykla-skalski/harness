import Foundation
import Observation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Harness Monitor store navigation history")
struct HarnessMonitorStoreNavigationTests {

  // MARK: - Direct selectSession path (proves store logic)

  @Test("Selecting session from dashboard pushes nil to back stack")
  func selectFromDashboard() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    #expect(store.navigationBackStack.count == 1)
    #expect(store.navigationBackStack.first == nil as String?)
  }

  @Test("Selecting two sessions populates the back stack")
  func selectTwoSessions() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("Navigate back restores previous session and populates forward stack")
  func navigateBack() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()

    #expect(store.selectedSessionID == "sess-a")
    #expect(store.navigationBackStack == [nil])
    #expect(store.navigationForwardStack == ["sess-b"] as [String?])
  }

  @Test("Navigate back to dashboard clears selection")
  func navigateBackToDashboard() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.navigateBack()

    #expect(store.selectedSessionID == nil)
    #expect(store.navigationBackStack.isEmpty)
    #expect(store.navigationForwardStack == ["sess-a"] as [String?])
  }

  @Test("Navigate forward after back restores forward session")
  func navigateForward() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()
    await store.navigateForward()

    #expect(store.selectedSessionID == "sess-b")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("New selection after back clears forward stack")
  func newSelectionClearsForward() async throws {
    let store = try await makeNavigationStore()

    await store.selectSession("sess-a")
    await store.selectSession("sess-b")
    await store.navigateBack()
    await store.selectSession("sess-c")

    #expect(store.selectedSessionID == "sess-c")
    #expect(store.navigationBackStack == [nil, "sess-a"])
    #expect(store.navigationForwardStack.isEmpty)
  }

  @Test("Sidebar flow: primeSessionSelection then selectSession records history")
  func sidebarPrimeThenSelect() async throws {
    let store = try await makeNavigationStore()

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
  func backStackMutationIsObservable() async throws {
    let store = try await makeNavigationStore()

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

  @Test("Updating navigation availability keeps handler routing intact")
  func updatingNavigationAvailabilityKeepsHandlers() async {
    let backRecorder = ConfirmationRecorder()
    let forwardRecorder = ConfirmationRecorder()
    let state = WindowNavigationState()
    state.setHandlers(
      back: { Task { await backRecorder.record() } },
      forward: { Task { await forwardRecorder.record() } }
    )

    let updated = state.updating(canGoBack: true, canGoForward: true)

    #expect(updated.canGoBack)
    #expect(updated.canGoForward)

    updated.navigateBack()
    updated.navigateForward()

    // The handlers hand off to an actor through a detached Task, so a single
    // yield can race the recording under load. Wait (bounded) until both
    // handlers have recorded before asserting, instead of assuming one yield
    // is enough for the actor hop.
    for _ in 0..<1000 {
      if await backRecorder.count >= 1, await forwardRecorder.count >= 1 {
        break
      }
      await Task.yield()
    }

    #expect(await backRecorder.count == 1)
    #expect(await forwardRecorder.count == 1)
  }

  @Test("Updating with unchanged availability keeps the snapshot stable")
  func updatingWithSameAvailabilityKeepsSnapshotStable() async {
    let state = WindowNavigationState()
    let updated = state.updating(canGoBack: false, canGoForward: false)
    #expect(updated.canGoBack == state.canGoBack)
    #expect(updated.canGoForward == state.canGoForward)
  }

  @Test("Global window history navigates between dashboard and session selections")
  func globalWindowHistoryNavigatesAcrossWindows() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordSessionSelection(sessionID: "sess-a", selection: .route(.overview))

    #expect(history.canGoBack)
    #expect(!history.canGoForward)

    history.navigateBack()

    let dashboardRequest = try #require(history.pendingDashboardRestoreRequest)
    #expect(dashboardRequest.route == .taskBoard)
    #expect(!history.canGoBack)
    #expect(history.canGoForward)

    history.finishDashboardRestoreRequest(dashboardRequest.requestID)
    history.navigateForward()

    let sessionRequest = try #require(history.pendingSessionRestoreRequest)
    #expect(sessionRequest.sessionID == "sess-a")
    #expect(sessionRequest.selection == .route(.overview))
    #expect(history.canGoBack)
    #expect(!history.canGoForward)
  }

  @Test("Global window history starts from the restored dashboard route")
  func globalWindowHistoryStartsFromRestoredDashboardRoute() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(
      store: store,
      initialDashboardRoute: .reviews
    )

    #expect(history.dashboardSelection == .route(.reviews))
    #expect(history.currentEntry == .dashboard(selection: .route(.reviews)))
    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
  }

  @Test("Global window history replaces the default entry with the mounted dashboard route")
  func globalWindowHistoryReplacesDefaultEntryWithMountedDashboardRoute() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .reviews)

    #expect(history.dashboardSelection == .route(.reviews))
    #expect(history.currentEntry == .dashboard(selection: .route(.reviews)))
    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
  }

  @Test("Global window history skips non-restorable session entries")
  func globalWindowHistorySkipsStaleSessions() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordSessionSelection(sessionID: "sess-a", selection: .route(.overview))
    history.recordSessionSelection(sessionID: "missing-session", selection: .route(.timeline))
    history.recordDashboardRoute(.reviews)

    history.navigateBack()

    let sessionRequest = try #require(history.pendingSessionRestoreRequest)
    #expect(sessionRequest.sessionID == "sess-a")
    #expect(sessionRequest.selection == .route(.overview))
    #expect(history.canGoForward)
  }

  @Test("Global window history upgrades generic Reviews route entries in place")
  func globalWindowHistoryUpgradesGenericReviewsEntriesInPlace() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)
    let overviewSelection = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-42"],
      primaryPullRequestID: "PR-42",
      detailMode: .overview
    )

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(overviewSelection))

    history.navigateBack()

    let dashboardRequest = try #require(history.pendingDashboardRestoreRequest)
    #expect(dashboardRequest.route == .taskBoard)
    #expect(history.pendingDashboardReviewsRestoreRequest == nil)
    #expect(!history.canGoBack)
    #expect(history.canGoForward)
  }

  @Test("Global window history restores Reviews Files selections on back and forward")
  func globalWindowHistoryRestoresReviewsFilesSelections() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)
    let overviewSelection = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-42"],
      primaryPullRequestID: "PR-42",
      detailMode: .overview
    )
    let filesSelection = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-42"],
      primaryPullRequestID: "PR-42",
      detailMode: .files
    )

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(overviewSelection))
    history.recordDashboardSelection(.reviews(filesSelection))

    history.navigateBack()

    let backDashboardRequest = try #require(history.pendingDashboardRestoreRequest)
    let backReviewsRequest = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(backDashboardRequest.selection == .reviews(overviewSelection))
    #expect(backReviewsRequest.selection == overviewSelection)
    history.finishDashboardRestoreRequest(backDashboardRequest.requestID)
    history.finishDashboardReviewsRestoreRequest(backReviewsRequest.requestID)

    history.navigateForward()

    let forwardDashboardRequest = try #require(history.pendingDashboardRestoreRequest)
    let forwardReviewsRequest = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(forwardDashboardRequest.selection == .reviews(filesSelection))
    #expect(forwardReviewsRequest.selection == filesSelection)
    #expect(history.canGoBack)
    #expect(!history.canGoForward)
  }

  // MARK: - Fixtures

  func makeNavigationStore() async throws -> HarnessMonitorStore {
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
        (
          summary.sessionId,
          makeSessionDetail(
            summary: summary,
            workerID: "worker-\(summary.sessionId)",
            workerName: "Worker \(summary.sessionId)"
          )
        )
      }
    )
    let client = RecordingHarnessClient(detail: try #require(details.values.first))
    client.configureSessions(summaries: summaries, detailsByID: details)
    return await makeBootstrappedStore(client: client)
  }

  func reviewsOverview() -> DashboardReviewsHistorySelection {
    DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1"],
      primaryPullRequestID: "PR-1",
      detailMode: .overview
    )
  }

  func reviewsFile(
    line: Int?,
    path: String = "Sources/A.swift"
  ) -> DashboardReviewsHistorySelection {
    DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1"],
      primaryPullRequestID: "PR-1",
      detailMode: .files,
      selectedFilePath: path,
      lineSelection: line.map { ReviewLineSelection(line: $0) }
    )
  }
}

private actor ConfirmationRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
