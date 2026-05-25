import Foundation
import Observation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension HarnessMonitorStoreNavigationTests {
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

  @Test("Entering Files coalesces the async path settle into one clean entry")
  func reviewsEntryTransitionCoalescesAsyncSettle() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(reviewsOverview()))
    #expect(history.currentEntry == .dashboard(selection: .reviews(reviewsOverview())))

    // Mirror enterFilesMode: the route view brackets the entry, then selectedPath
    // settles nil -> remembered(stale) -> resolved as prepareFilesMode restores the
    // remembered file and ensureSelectedPath picks the final one. Each step fires
    // the route view's onChange recorders.
    let filesNoPath = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-1"],
      primaryPullRequestID: "PR-1",
      detailMode: .files,
      selectedFilePath: nil,
      lineSelection: nil
    )
    history.beginReviewsEntryTransition()
    history.recordDashboardSelection(.reviews(filesNoPath))
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil, path: "Sources/Stale.swift")))
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil, path: "Sources/A.swift")))

    // Mid-transition: the mirror tracks reality, but nothing is stacked yet -
    // currentEntry is still the overview we entered from.
    #expect(
      history.dashboardSelection == .reviews(reviewsFile(line: nil, path: "Sources/A.swift"))
    )
    #expect(history.currentEntry == .dashboard(selection: .reviews(reviewsOverview())))

    // Settle completes: close the bracket and record the resolved selection once.
    history.endReviewsEntryTransition()
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil, path: "Sources/A.swift")))
    #expect(
      history.currentEntry
        == .dashboard(selection: .reviews(reviewsFile(line: nil, path: "Sources/A.swift")))
    )

    // Exactly one entry pushed: Back lands on the overview, never on a throwaway
    // files(no path) or files(stale) intermediate.
    history.navigateBack()
    let backReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(backReviews.selection == reviewsOverview())

    // Forward returns to the resolved file, proving the single entry round-trips.
    let backDashboard = try #require(history.pendingDashboardRestoreRequest)
    history.finishDashboardRestoreRequest(backDashboard.requestID)
    history.finishDashboardReviewsRestoreRequest(backReviews.requestID)
    history.navigateForward()
    let forwardReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(forwardReviews.selection == reviewsFile(line: nil, path: "Sources/A.swift"))
  }

  @Test("Rapid back-to-back Files entries still collapse to a single entry")
  func reviewsEntryTransitionNestsAcrossRapidEntries() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordDashboardRoute(.reviews)
    history.recordDashboardSelection(.reviews(reviewsOverview()))

    // Two entries open before either settle finishes (PR-A then PR-B). The
    // depth counter must keep suppressing until the outermost bracket closes.
    history.beginReviewsEntryTransition()
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil, path: "Sources/A.swift")))
    history.beginReviewsEntryTransition()
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil, path: "Sources/B.swift")))

    // First settle closes the inner bracket: still suppressed (depth 1), so the
    // record does not stack and currentEntry stays at the overview.
    history.endReviewsEntryTransition()
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil, path: "Sources/B.swift")))
    #expect(history.currentEntry == .dashboard(selection: .reviews(reviewsOverview())))

    // Outermost bracket closes: the settled selection records exactly once.
    history.endReviewsEntryTransition()
    history.recordDashboardSelection(.reviews(reviewsFile(line: nil, path: "Sources/B.swift")))
    #expect(
      history.currentEntry
        == .dashboard(selection: .reviews(reviewsFile(line: nil, path: "Sources/B.swift")))
    )

    history.navigateBack()
    let backReviews = try #require(history.pendingDashboardReviewsRestoreRequest)
    #expect(backReviews.selection == reviewsOverview())
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
}
