import AppIntents
import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class MutatingReviewsIntentTests: XCTestCase {
  func testApproveForwardsPullRequestIDToSource() async throws {
    let stub = StubReviewsActionSource()
    let intent = ApprovePullRequestIntent(
      pullRequest: Self.makeEntity(id: "owner/repo#1"),
      source: stub
    )

    try await intent.applyApproval()

    let recorded = await stub.recordedApprovals
    XCTAssertEqual(recorded, ["owner/repo#1"])
  }

  func testMergeForwardsPullRequestIDAndMethodToSource() async throws {
    let stub = StubReviewsActionSource()
    let intent = MergePullRequestIntent(
      pullRequest: Self.makeEntity(id: "owner/repo#2"),
      method: .rebase,
      source: stub
    )

    try await intent.applyMerge()

    let recorded = await stub.recordedMerges
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.pullRequestID, "owner/repo#2")
    XCTAssertEqual(recorded.first?.method, .rebase)
  }

  func testRerunChecksForwardsPullRequestIDToSource() async throws {
    let stub = StubReviewsActionSource()
    let intent = RerunChecksIntent(
      pullRequest: Self.makeEntity(id: "owner/repo#3"),
      source: stub
    )

    try await intent.applyRerun()

    let recorded = await stub.recordedReruns
    XCTAssertEqual(recorded, ["owner/repo#3"])
  }

  func testAddLabelForwardsPullRequestIDAndLabelToSource() async throws {
    let stub = StubReviewsActionSource()
    let intent = AddLabelToPullRequestIntent(
      pullRequest: Self.makeEntity(id: "owner/repo#4"),
      label: "needs-review",
      source: stub
    )

    try await intent.applyLabel()

    let recorded = await stub.recordedLabels
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.pullRequestID, "owner/repo#4")
    XCTAssertEqual(recorded.first?.label, "needs-review")
  }

  func testMergeMethodEnumMapsToDaemonValues() {
    XCTAssertEqual(MergeMethodEnum.squash.daemonValue, .squash)
    XCTAssertEqual(MergeMethodEnum.merge.daemonValue, .merge)
    XCTAssertEqual(MergeMethodEnum.rebase.daemonValue, .rebase)
  }

  // MARK: - helpers

  private static func makeEntity(id: String) -> PullRequestEntity {
    PullRequestEntity(
      id: id,
      title: "Title for \(id)",
      repository: id.split(separator: "#").first.map(String.init) ?? "owner/repo",
      number: Int(id.split(separator: "#").last.map(String.init) ?? "0") ?? 0,
      authorLogin: "alice",
      state: .open,
      reviewerSummary: "0/0 approvals",
      lastUpdated: nil,
      url: URL(string: "https://example.com/\(id)")
    )
  }
}

actor StubReviewsActionSource: ReviewsActionSource {
  private(set) var recordedApprovals: [String] = []
  private(set) var recordedMerges: [(pullRequestID: String, method: TaskBoardGitHubMergeMethod)] = []
  private(set) var recordedReruns: [String] = []
  private(set) var recordedLabels: [(pullRequestID: String, label: String)] = []

  func approve(pullRequestID: String) async throws {
    recordedApprovals.append(pullRequestID)
  }

  func merge(pullRequestID: String, method: TaskBoardGitHubMergeMethod) async throws {
    recordedMerges.append((pullRequestID, method))
  }

  func rerunChecks(pullRequestID: String) async throws {
    recordedReruns.append(pullRequestID)
  }

  func addLabel(pullRequestID: String, label: String) async throws {
    recordedLabels.append((pullRequestID, label))
  }
}
