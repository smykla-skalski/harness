import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class DependencyUpdateTimelineViewModelTests: XCTestCase {
  private func issueComment(id: String, body: String) -> DependencyUpdateTimelineEntry {
    .issueComment(
      IssueCommentPayload(id: id, createdAt: "2026-05-22T10:00:00Z", body: body)
    )
  }

  private func samplePage(
    entries: [DependencyUpdateTimelineEntry],
    hasOlder: Bool = false,
    startCursor: String? = nil
  ) -> DependencyUpdatesTimelineResponse {
    DependencyUpdatesTimelineResponse(
      pullRequestId: "PR_vm",
      entries: entries,
      pageInfo: DependencyUpdateTimelinePageInfo(
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
    let vm = DependencyUpdateTimelineViewModel()
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
    XCTAssertEqual(vm.startCursor, "start")
    XCTAssertTrue(vm.hasOlder)
    XCTAssertTrue(vm.viewerCanComment)
    XCTAssertEqual(vm.loadState, .idle)
    XCTAssertNil(vm.lastError)
  }

  func testAppendOlderPrependsAndUpdatesCursor() {
    let vm = DependencyUpdateTimelineViewModel()
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
    XCTAssertFalse(vm.hasOlder)
    XCTAssertEqual(vm.loadState, .idle)
  }

  func testMarkFailedSurfacesReason() {
    let vm = DependencyUpdateTimelineViewModel()
    vm.markLoading(.loadingInitial)
    vm.markFailed(reason: "rate limit reached")
    XCTAssertEqual(vm.loadState, .failed)
    XCTAssertEqual(vm.lastError, "rate limit reached")
  }

  func testClearResetsEverything() {
    let vm = DependencyUpdateTimelineViewModel()
    vm.apply(initial: samplePage(entries: [issueComment(id: "x", body: "")], hasOlder: true))
    vm.clear()
    XCTAssertTrue(vm.entries.isEmpty)
    XCTAssertNil(vm.startCursor)
    XCTAssertFalse(vm.hasOlder)
    XCTAssertEqual(vm.loadState, .idle)
  }
}
