import Foundation
import XCTest

// Contract: `act9.ready` must fire while both reviewers are still in the
// `claimed` state and before either submits a verdict. The Inspector's
// `ReviewStatePanel` only renders `reviewer-claim-badge.*` and
// `reviewer-quorum.*` while `task.awaitingReview != nil ||
// task.reviewClaim != nil`. Once both `submit-review` calls land the task
// transitions out of `awaiting_review`, both fields clear, the panel
// disappears, and the swarm UI test fails the act9 expectation. Pinning
// the act9 ordering here prevents the orchestrator from regressing back
// into the post-quorum window.
final class SwarmAct9OrderingContractTests: XCTestCase {
  func testAct9ReadyEmittedBeforeFirstSubmitReview() throws {
    let orchestrator = try loadOrchestrator()

    let act9Range = try locate(
      pattern: #"actReady\(\s*\n?\s*"act9""#,
      in: orchestrator,
      label: "actReady(\"act9\""
    )
    let firstSubmitReviewRange = try locate(
      pattern: #""submit-review""#,
      in: orchestrator,
      label: "first \"submit-review\""
    )

    XCTAssertLessThan(
      act9Range.lowerBound,
      firstSubmitReviewRange.lowerBound,
      """
      `actReady("act9", …)` must run before the first `submit-review` so the \
      Inspector's reviewer-claim / reviewer-quorum badges are still rendered \
      when the swarm UI fixture snapshots the act9 hierarchy.
      """
    )
  }

  func testAct9ReadyEmittedAfterBothClaimReviews() throws {
    let orchestrator = try loadOrchestrator()

    let claimReviewRanges = locateAll(
      pattern: #""claim-review""#,
      in: orchestrator
    )
    XCTAssertGreaterThanOrEqual(
      claimReviewRanges.count,
      2,
      "Orchestrator must execute at least two `claim-review` calls before act9.ready."
    )
    let secondClaimReview = claimReviewRanges[1]
    let act9Range = try locate(
      pattern: #"actReady\(\s*\n?\s*"act9""#,
      in: orchestrator,
      label: "actReady(\"act9\""
    )

    XCTAssertGreaterThan(
      act9Range.lowerBound,
      secondClaimReview.lowerBound,
      """
      `actReady("act9", …)` must run after both `claim-review` calls so the \
      reviewer-claim badges have a chance to propagate to the Inspector \
      before the swarm UI fixture snapshots the act9 hierarchy.
      """
    )
  }

  private func loadOrchestrator() throws -> String {
    try String(
      contentsOf: repoRoot().appendingPathComponent(
        "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift"
      ),
      encoding: .utf8
    )
  }

  private func locate(
    pattern: String,
    in text: String,
    label: String
  ) throws -> Range<String.Index> {
    guard
      let range = text.range(
        of: pattern,
        options: [.regularExpression]
      )
    else {
      throw NSError(
        domain: "SwarmAct9OrderingContractTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not find \(label) in orchestrator source."]
      )
    }
    return range
  }

  private func locateAll(pattern: String, in text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while let match = text.range(of: pattern, options: [.regularExpression], range: searchStart..<text.endIndex) {
      ranges.append(match)
      searchStart = match.upperBound
    }
    return ranges
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // HarnessMonitorE2ECoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // HarnessMonitorE2E
      .deletingLastPathComponent()  // Tools
      .deletingLastPathComponent()  // harness-monitor-macos
      .deletingLastPathComponent()  // apps
      .deletingLastPathComponent()  // repo root
  }
}
