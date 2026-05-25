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
    await Task.yield()

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

  private func reviewsOverview() -> DashboardReviewsHistorySelection {
    DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1"],
      primaryPullRequestID: "PR-1",
      detailMode: .overview
    )
  }

  private func reviewsFile(
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

  @Test("History selection drops file/line outside Files mode")
  func historySelectionDropsFileLineOutsideFilesMode() {
    let overview = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1"],
      primaryPullRequestID: "PR-1",
      detailMode: .overview,
      selectedFilePath: "A.swift",
      lineSelection: ReviewLineSelection(line: 5)
    )
    #expect(overview.selectedFilePath == nil)
    #expect(overview.lineSelection == nil)

    let files = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1"],
      primaryPullRequestID: "PR-1",
      detailMode: .files,
      selectedFilePath: "A.swift",
      lineSelection: ReviewLineSelection(line: 5)
    )
    #expect(files.selectedFilePath == "A.swift")
    #expect(files.lineSelection == ReviewLineSelection(line: 5))

    let multi = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1", "PR-2"],
      primaryPullRequestID: "PR-1",
      detailMode: .files,
      selectedFilePath: "A.swift",
      lineSelection: ReviewLineSelection(line: 5)
    )
    #expect(multi.detailMode == .overview)
    #expect(multi.selectedFilePath == nil)
    #expect(multi.lineSelection == nil)

    let lineWithoutFile = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1"],
      primaryPullRequestID: "PR-1",
      detailMode: .files,
      selectedFilePath: nil,
      lineSelection: ReviewLineSelection(line: 5)
    )
    #expect(lineWithoutFile.lineSelection == nil)
  }

  @Test("Line nudges within one file coalesce so back skips to the previous entry")
  func reviewsLineChangesCoalesceWithinFile() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)
    let overview = reviewsOverview()

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(overview))
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil)))
    history.recordDashboardSelection(.reviews(reviewsFile(line: 10)))
    history.recordDashboardSelection(.reviews(reviewsFile(line: 20)))

    history.navigateBack()
    let backDashboard = try #require(history.pendingDashboardRestoreRequest)
    let backReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(backReviews.selection == overview)
    history.finishDashboardRestoreRequest(backDashboard.requestID)
    history.finishDashboardReviewsRestoreRequest(backReviews.requestID)

    history.navigateForward()
    let forwardReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(forwardReviews.selection == reviewsFile(line: 20))
    #expect(!history.canGoForward)
  }

  @Test("A reviews jump pushes a new entry even for a line-only change")
  func reviewsJumpPushesLineOnlyChange() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(reviewsOverview()))
    history.recordDashboardSelection(.reviews(reviewsFile(line: 10)))
    history.recordReviewsJump(reviewsFile(line: 50))

    history.navigateBack()
    let backReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(backReviews.selection == reviewsFile(line: 10))
  }

  @Test("Switching files pushes a new entry instead of coalescing")
  func reviewsFileSwitchPushes() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(reviewsOverview()))
    history.recordDashboardSelection(.reviews(reviewsFile(line: 10, path: "Sources/A.swift")))
    history.recordDashboardSelection(.reviews(reviewsFile(line: 5, path: "Sources/B.swift")))

    history.navigateBack()
    let backReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(backReviews.selection == reviewsFile(line: 10, path: "Sources/A.swift"))
  }

  @Test("Requesting a file jump pushes one entry and arms the reviews restore")
  func reviewsFileJumpPushesAndArmsRestore() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(reviewsOverview()))

    history.requestReviewsFileJump(reviewsFile(line: 10))

    #expect(history.dashboardSelection == .reviews(reviewsFile(line: 10)))
    #expect(history.currentEntry == .dashboard(selection: .reviews(reviewsFile(line: 10))))
    let dashboardRequest = try #require(history.pendingDashboardRestoreRequest)
    let reviewsRequest = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(dashboardRequest.selection == .reviews(reviewsFile(line: 10)))
    #expect(reviewsRequest.selection == reviewsFile(line: 10))
    #expect(history.pendingSessionRestoreRequest == nil)
    #expect(history.canGoBack)
    #expect(!history.canGoForward)

    // Back returns to the entry the reviewer was on, proving the jump pushed a
    // real history entry rather than replacing the current one.
    history.finishDashboardRestoreRequest(dashboardRequest.requestID)
    history.finishDashboardReviewsRestoreRequest(reviewsRequest.requestID)
    history.navigateBack()
    let backReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(backReviews.selection == reviewsOverview())
  }

  @Test("Deep-link URL drives a file jump end to end through router, registry, and history")
  func deepLinkFileURLDrivesFileJumpEndToEnd() async throws {
    // URL -> router -> typed file target (the path keeps its slashes and the
    // encoded space decodes).
    let url = try #require(
      URL(
        string:
          "harness://reviews/octo/repo/42/files/Sources/App%20Core/Main.swift?lines=10-20&side=left"
      )
    )
    let route = try #require(HarnessMonitorDeepLinkRouter.parse(url: url))
    guard case .pullRequest(let id, let parsedFile?) = route else {
      Issue.record("expected a pull-request file route, got \(route)")
      return
    }
    #expect(id == "octo/repo#42")
    #expect(parsedFile.path == "Sources/App Core/Main.swift")
    #expect(parsedFile.lines == ReviewLineSelection(start: 10, end: 20, side: .left))

    // Router rebuilds the same URL: this is the Copy Harness Link round-trip the
    // diff gutter produces.
    let rebuilt = try #require(
      HarnessMonitorDeepLinkRouter.url(for: .pullRequest(id: id, file: parsedFile))
    )
    let rebuiltRoute = try #require(HarnessMonitorDeepLinkRouter.parse(url: rebuilt))
    guard case .pullRequest(let rebuiltID, let rebuiltFile?) = rebuiltRoute else {
      Issue.record("expected the rebuilt URL to parse back to a file route")
      return
    }
    #expect(rebuiltID == id)
    #expect(rebuiltFile == parsedFile)

    // App bridge -> review registry carries the file + line target.
    let registry = OpenAnythingDashboardReviewRegistry()
    registry.requestSelection(
      pullRequestID: id,
      filePath: parsedFile.path,
      lineSelection: parsedFile.lines
    )
    let request = try #require(registry.selectionRequest)
    #expect(request.filePath == parsedFile.path)
    #expect(request.lineSelection == parsedFile.lines)

    // Route view -> history file jump: one pushed entry, Files mode, lines kept.
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)
    history.installDashboardStateIfNeeded(route: .reviews)
    let jump = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: [request.pullRequestID],
      primaryPullRequestID: request.pullRequestID,
      detailMode: .files,
      selectedFilePath: request.filePath,
      lineSelection: request.lineSelection
    )
    history.requestReviewsFileJump(jump)
    let arrival = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(arrival.selection == jump)
    #expect(arrival.selection.selectedFilePath == "Sources/App Core/Main.swift")
    #expect(arrival.selection.lineSelection == ReviewLineSelection(start: 10, end: 20, side: .left))

    // Back returns to the prior Reviews view; forward returns to the file.
    let arrivalDashboard = try #require(history.pendingDashboardRestoreRequest)
    history.finishDashboardRestoreRequest(arrivalDashboard.requestID)
    history.finishDashboardReviewsRestoreRequest(arrival.requestID)
    history.navigateBack()
    let back = try #require(history.pendingDashboardRestoreRequest)
    #expect(back.route == .reviews)
    #expect(history.pendingDashboardReviewsRestoreRequest == nil)
    history.finishDashboardRestoreRequest(back.requestID)
    #expect(history.canGoForward)
    history.navigateForward()
    let forward = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(forward.selection == jump)
  }

  @Test("Command routing scope persists until the active window is explicitly cleared")
  func commandRoutingScopePersistsUntilClear() async {
    let routingState = WindowCommandRoutingState()
    let mainWindow = NSObject()
    let decisionDeskRoot = NSObject()

    routingState.activate(scope: .main, windowID: ObjectIdentifier(mainWindow))
    #expect(routingState.activeScope == .main)

    routingState.activate(scope: .session, windowID: ObjectIdentifier(decisionDeskRoot))
    #expect(routingState.activeScope == .session)

    routingState.clear(windowID: ObjectIdentifier(mainWindow))
    #expect(
      routingState.activeScope == .session,
      "Clearing a background window must not drop routing for the active window"
    )

    routingState.clear(windowID: ObjectIdentifier(decisionDeskRoot))
    #expect(routingState.activeScope == nil)
  }

  // MARK: - Fixtures

  private func makeNavigationStore() async throws -> HarnessMonitorStore {
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

}

private actor ConfirmationRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
