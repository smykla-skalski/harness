import Foundation
import XCTest

final class SwarmArbitrationRoundsContractTests: XCTestCase {
  func testArbitrationLoopUsesOneSubmitForReviewAndTwoContinueRounds() throws {
    let block = try extractActDriverRunBody()
    let submitRequestChangesCalls = countOccurrences(of: "submitRequestChangesRound(", in: block)
    let continueReviewCalls = countOccurrences(of: "continueReviewRound(", in: block)
    XCTAssertEqual(
      submitRequestChangesCalls,
      1,
      """
      Act driver `run()` must invoke `submitRequestChangesRound` exactly once for the \
      arbitration task. Subsequent rounds keep the task in `in_review`, so retrying \
      `submit-for-review` would fail with HTTP 409.
      """
    )
    XCTAssertEqual(
      continueReviewCalls,
      2,
      """
      Act driver `run()` must invoke `continueReviewRound` twice (rounds 2 and 3) so the \
      arbitration task hits review_round=3 via submit-review/respond-review only.
      """
    )
  }

  func testActDriverRunNeverMayFailsTaskUpdate() throws {
    let block = try extractActDriverRunBody()
    XCTAssertFalse(
      containsMayFailUpdate(block),
      """
      Act driver `run()` must not call `runHarnessMayFail([..., "session", "task", "update", ...])`. \
      The state machine rejects generic `update` on `in_review`, so the call always silently fails \
      and masks the real arbitration-round bug.
      """
    )
  }

  func testOrchestratorExposesContinueReviewRoundHelper() throws {
    let source = try orchestratorSource()
    XCTAssertTrue(
      source.contains("private func continueReviewRound("),
      """
      Orchestrator must expose `continueReviewRound(taskID:workerID:reviewerA:reviewerB:note:)` \
      so subsequent arbitration rounds drive submit-review×2 + respond-review without retrying \
      submit-for-review against an already in-review task.
      """
    )
  }

  private func orchestratorSource() throws -> String {
    try String(
      contentsOf: repoRoot().appendingPathComponent(
        "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift"
      ),
      encoding: .utf8
    )
  }

  private func extractActDriverRunBody() throws -> String {
    let source = try orchestratorSource()
    guard let startRange = source.range(of: "  func run() throws {") else {
      throw XCTSkip("act-driver run() not found in orchestrator source")
    }
    let tail = source[startRange.lowerBound...]
    guard let openBraceRange = tail.range(of: "{") else {
      throw XCTSkip("act-driver run() opening brace missing")
    }
    var depth = 0
    var index = openBraceRange.lowerBound
    while index < tail.endIndex {
      let character = tail[index]
      if character == "{" { depth += 1 }
      if character == "}" {
        depth -= 1
        if depth == 0 {
          let bodyRange = openBraceRange.upperBound..<index
          return String(tail[bodyRange])
        }
      }
      index = tail.index(after: index)
    }
    throw XCTSkip("act-driver run() body did not close")
  }

  private func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, options: [], range: searchRange) {
      count += 1
      searchRange = found.upperBound..<haystack.endIndex
    }
    return count
  }

  private func containsMayFailUpdate(_ block: String) -> Bool {
    let pattern =
      #"runHarnessMayFail\(\[[^\]]*"session"\s*,\s*"task"\s*,\s*"update""#
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.dotMatchesLineSeparators]
      )
    else { return false }
    let range = NSRange(block.startIndex..., in: block)
    return expression.firstMatch(in: block, options: [], range: range) != nil
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
