import Foundation
import XCTest

@testable import HarnessMonitorIntents

final class IntentDonationRecorderTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "io.harnessmonitor.test.donations.\(UUID().uuidString)"
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    suiteName = nil
    super.tearDown()
  }

  private func makeRecorder(capacity: Int = 20) -> IntentDonationRecorder {
    IntentDonationRecorder(
      capacity: capacity,
      defaults: UserDefaults(suiteName: suiteName),
      storageKey: "test-donations"
    )
  }

  func testRecentIDsReturnsMostRecentFirst() async {
    let recorder = makeRecorder(capacity: 5)
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.recordDonation(pullRequestID: "b")
    await recorder.recordDonation(pullRequestID: "c")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["c", "b", "a"])
  }

  func testDuplicateDonationMovesEntryToFront() async {
    let recorder = makeRecorder(capacity: 5)
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.recordDonation(pullRequestID: "b")
    await recorder.recordDonation(pullRequestID: "a")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["a", "b"])
  }

  func testCapacityEvictsOldestEntryOfSameKind() async {
    let recorder = makeRecorder(capacity: 3)
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.recordDonation(pullRequestID: "b")
    await recorder.recordDonation(pullRequestID: "c")
    await recorder.recordDonation(pullRequestID: "d")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["d", "c", "b"])
  }

  func testEmptyOrBlankIDsAreIgnored() async {
    let recorder = makeRecorder()
    await recorder.recordDonation(pullRequestID: "")
    await recorder.recordDonation(pullRequestID: "   ")
    await recorder.recordDonation(pullRequestID: "a")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["a"])
  }

  func testClearWipesRecorder() async {
    let recorder = makeRecorder()
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.clear()

    let count = await recorder.countForTesting
    XCTAssertEqual(count, 0)
  }

  func testKindsAreIsolated() async {
    let recorder = makeRecorder()
    await recorder.recordDonation(kind: .pullRequest, id: "pr-1")
    await recorder.recordDonation(kind: .taskBoardItem, id: "task-1")
    await recorder.recordDonation(kind: .repository, id: "octo/repo")
    await recorder.recordDonation(kind: .pullRequest, id: "pr-2")

    let prs = await recorder.recentIDs(kind: .pullRequest)
    let tasks = await recorder.recentIDs(kind: .taskBoardItem)
    let repos = await recorder.recentIDs(kind: .repository)

    XCTAssertEqual(prs, ["pr-2", "pr-1"])
    XCTAssertEqual(tasks, ["task-1"])
    XCTAssertEqual(repos, ["octo/repo"])
  }

  func testCapacityIsPerKind() async {
    let recorder = makeRecorder(capacity: 2)
    await recorder.recordDonation(kind: .pullRequest, id: "pr-1")
    await recorder.recordDonation(kind: .pullRequest, id: "pr-2")
    await recorder.recordDonation(kind: .pullRequest, id: "pr-3")
    await recorder.recordDonation(kind: .taskBoardItem, id: "task-1")
    await recorder.recordDonation(kind: .taskBoardItem, id: "task-2")

    let prs = await recorder.recentIDs(kind: .pullRequest)
    let tasks = await recorder.recentIDs(kind: .taskBoardItem)

    XCTAssertEqual(prs, ["pr-3", "pr-2"], "oldest PR should be evicted; tasks left intact")
    XCTAssertEqual(tasks, ["task-2", "task-1"])
  }

  func testEntriesPersistAcrossInstances() async {
    let writer = makeRecorder()
    await writer.recordDonation(kind: .pullRequest, id: "pr-1")
    await writer.recordDonation(kind: .taskBoardItem, id: "task-1")
    await writer.recordDonation(kind: .repository, id: "octo/repo")

    let reader = makeRecorder()
    let prs = await reader.recentIDs(kind: .pullRequest)
    let tasks = await reader.recentIDs(kind: .taskBoardItem)
    let repos = await reader.recentIDs(kind: .repository)

    XCTAssertEqual(prs, ["pr-1"])
    XCTAssertEqual(tasks, ["task-1"])
    XCTAssertEqual(repos, ["octo/repo"])
  }

  func testClearRemovesAllKindsFromBackingStore() async {
    let writer = makeRecorder()
    await writer.recordDonation(kind: .pullRequest, id: "pr-1")
    await writer.recordDonation(kind: .taskBoardItem, id: "task-1")
    await writer.clear()

    let reader = makeRecorder()
    let prs = await reader.recentIDs(kind: .pullRequest)
    let tasks = await reader.recentIDs(kind: .taskBoardItem)

    XCTAssertTrue(prs.isEmpty)
    XCTAssertTrue(tasks.isEmpty)
  }

  func testLegacyPullRequestAPIRoutesToPullRequestKind() async {
    let recorder = makeRecorder()
    await recorder.recordDonation(pullRequestID: "pr-1")

    let viaKind = await recorder.recentIDs(kind: .pullRequest)
    let viaLegacy = await recorder.recentIDs()

    XCTAssertEqual(viaKind, ["pr-1"])
    XCTAssertEqual(viaLegacy, ["pr-1"])
  }

  func testRecorderWithNilDefaultsStaysQuiet() async {
    let recorder = IntentDonationRecorder(
      capacity: 5,
      defaults: nil,
      storageKey: "ignored"
    )
    await recorder.recordDonation(pullRequestID: "pr-1")

    let observed = await recorder.recentIDs()
    XCTAssertTrue(observed.isEmpty, "no backing store means no persistence")
  }
}
