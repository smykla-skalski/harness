import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class ReviewTimelineViewModelTests: XCTestCase {
  private func issueComment(id: String, body: String) -> ReviewTimelineEntry {
    .issueComment(
      IssueCommentPayload(id: id, createdAt: "2026-05-22T10:00:00Z", body: body)
    )
  }

  private func samplePage(
    entries: [ReviewTimelineEntry],
    hasOlder: Bool = false,
    startCursor: String? = nil
  ) -> ReviewsTimelineResponse {
    ReviewsTimelineResponse(
      pullRequestId: "PR_vm",
      entries: entries,
      pageInfo: ReviewTimelinePageInfo(
        startCursor: startCursor,
        endCursor: "end",
        hasOlder: hasOlder,
        hasNewer: false
      ),
      viewerCanComment: true,
      fetchedAt: "2026-05-22T15:00:00Z"
    )
  }

  func testApplyInitialPopulatesAndResetsState() {
    let vm = ReviewTimelineViewModel()
    vm.loadState = .loadingInitial
    vm.lastError = "previous failure"

    vm.apply(
      initial: samplePage(
        entries: [issueComment(id: "IC_1", body: "first")],
        hasOlder: true,
        startCursor: "start"
      )
    )

    XCTAssertEqual(vm.entries.count, 1)
    XCTAssertEqual(vm.entries[0].id, "IC_1")
    XCTAssertEqual(vm.revision, 1)
    XCTAssertEqual(vm.startCursor, "start")
    XCTAssertTrue(vm.hasOlder)
    XCTAssertTrue(vm.viewerCanComment)
    XCTAssertEqual(vm.loadState, .idle)
    XCTAssertNil(vm.lastError)
  }

  func testAppendOlderPrependsAndUpdatesCursor() {
    let vm = ReviewTimelineViewModel()
    vm.apply(
      initial: samplePage(
        entries: [issueComment(id: "IC_2", body: "second")],
        hasOlder: true,
        startCursor: "start-1"
      )
    )
    vm.markLoading(.loadingOlder)

    vm.appendOlder(
      samplePage(
        entries: [issueComment(id: "IC_1", body: "first")],
        hasOlder: false,
        startCursor: "start-0"
      )
    )

    XCTAssertEqual(vm.entries.map(\.id), ["IC_1", "IC_2"])
    XCTAssertEqual(vm.startCursor, "start-0")
    XCTAssertEqual(vm.revision, 2)
    XCTAssertFalse(vm.hasOlder)
    XCTAssertEqual(vm.loadState, .idle)
  }

  func testMarkFailedSurfacesReason() {
    let vm = ReviewTimelineViewModel()
    vm.markLoading(.loadingInitial)
    vm.markFailed(reason: "rate limit reached")
    XCTAssertEqual(vm.loadState, .failed)
    XCTAssertEqual(vm.lastError, "rate limit reached")
  }

  func testClearResetsEverything() {
    let vm = ReviewTimelineViewModel()
    vm.apply(initial: samplePage(entries: [issueComment(id: "x", body: "")], hasOlder: true))
    vm.clear()
    XCTAssertTrue(vm.entries.isEmpty)
    XCTAssertNil(vm.startCursor)
    XCTAssertFalse(vm.hasOlder)
    XCTAssertEqual(vm.loadState, .idle)
  }

  func testReplaceOptimisticKeepsSameCountButBumpsRevision() {
    let vm = ReviewTimelineViewModel()
    vm.appendOptimistic(issueComment(id: "optimistic-1", body: "draft"))
    let before = vm.revision

    vm.replaceOptimistic(
      id: "optimistic-1",
      with: issueComment(id: "IC_real", body: "draft")
    )

    XCTAssertEqual(vm.entries.map(\.id), ["IC_real"])
    XCTAssertEqual(vm.entries.count, 1)
    XCTAssertGreaterThan(vm.revision, before)
  }
}
