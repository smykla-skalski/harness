import Foundation
import XCTest

final class SwarmCleanupContractTests: XCTestCase {
  func testOrchestratorExposesDriveAllTasksToDoneHelper() throws {
    let source = try orchestratorSource()
    XCTAssertTrue(
      source.contains("private func driveAllTasksToDone("),
      """
      Orchestrator must expose `driveAllTasksToDone(leaderID:)` so the act driver \
      can drive every non-terminal task through the regular review/arbitration \
      flow before calling `harness session end`.
      """
    )
  }

  func testActDriverInvokesCleanupBetweenAct15AckAndSessionEnd() throws {
    let block = try extractActDriverRunBody()
    guard let act15AckRange = block.range(of: #"actAck("act15")"#) else {
      return XCTFail("act-driver run() missing actAck(\"act15\") call")
    }
    guard let cleanupRange = block.range(of: "try driveAllTasksToDone(") else {
      return XCTFail(
        """
        Act driver `run()` must call `try driveAllTasksToDone(...)` after `actAck("act15")` \
        and before the strict `runHarness session end` call.
        """
      )
    }
    guard let sessionEndRange = block.range(of: #""session", "end""#) else {
      return XCTFail("act-driver run() missing strict `\"session\", \"end\"` runHarness call")
    }
    XCTAssertLessThan(
      act15AckRange.upperBound,
      cleanupRange.lowerBound,
      "Cleanup helper must be invoked AFTER actAck(\"act15\")."
    )
    XCTAssertLessThan(
      cleanupRange.upperBound,
      sessionEndRange.lowerBound,
      "Cleanup helper must be invoked BEFORE the strict `session end` call."
    )
    XCTAssertEqual(
      countOccurrences(of: "driveAllTasksToDone(", in: block),
      1,
      "Cleanup helper must be invoked exactly once from `run()`."
    )
  }

  func testCleanupQueriesSessionStatusJSON() throws {
    let body = try extractPrivateFuncBody(named: "fetchSessionState")
    XCTAssertTrue(
      body.contains("\"session\""),
      "fetchSessionState must invoke a `session` subcommand."
    )
    XCTAssertTrue(
      body.contains("\"status\""),
      "fetchSessionState must invoke `session status` to enumerate every task."
    )
    XCTAssertTrue(
      body.contains("\"--json\""),
      "fetchSessionState must request `--json` so the orchestrator can parse the SessionState payload."
    )
  }

  func testCleanupDispatchesByStatusNotByHardcodedTaskID() throws {
    let body = try extractPrivateFuncBody(named: "driveTaskToDone")
    for status in [
      "\"open\"",
      "\"in_progress\"",
      "\"awaiting_review\"",
      "\"in_review\"",
      "\"blocked\"",
    ] {
      XCTAssertTrue(
        body.contains(status),
        "driveTaskToDone must dispatch on status literal \(status)."
      )
    }
    for forbidden in [
      "\"task-1\"",
      "\"task-2\"",
      "\"task-12\"",
      "taskAutospawnID",
      "taskRefusalID",
      "taskArbitrationID",
      "taskReviewID",
      "taskSignalID",
    ] {
      XCTAssertFalse(
        body.contains(forbidden),
        """
        driveTaskToDone must stay generic; \(forbidden) leaks act-driver-specific identity into \
        the cleanup dispatch. Drive whatever is in `state.tasks` from the JSON snapshot.
        """
      )
    }
  }

  func testCleanupReusesAliveReviewersBeforeJoiningNewOnes() throws {
    let body = try extractPrivateFuncBody(named: "cleanupReviewerPair")
    XCTAssertTrue(
      body.contains("\"agents\""),
      "cleanupReviewerPair must enumerate `state[\"agents\"]` before joining new reviewers."
    )
    XCTAssertTrue(
      body.contains("\"role\""),
      "cleanupReviewerPair must filter by agent `role` to find existing reviewers."
    )
    XCTAssertTrue(
      body.contains("\"reviewer\""),
      "cleanupReviewerPair must look for the `reviewer` role specifically."
    )
    guard let agentsScanRange = body.range(of: "\"agents\"") else {
      return XCTFail("cleanupReviewerPair body missing `\"agents\"` lookup")
    }
    if let joinRange = body.range(of: "joinAgent(") {
      XCTAssertLessThan(
        agentsScanRange.upperBound,
        joinRange.lowerBound,
        """
        cleanupReviewerPair must scan existing alive reviewers BEFORE falling back to \
        joinAgent(...) so cleanup reuses the arbitration-round reviewers when they are \
        still in the session.
        """
      )
    }
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

  private func extractPrivateFuncBody(named name: String) throws -> String {
    let source = try orchestratorSource()
    let needle = "private func \(name)("
    guard let startRange = source.range(of: needle) else {
      XCTFail("Orchestrator must declare `private func \(name)(...)`.")
      return ""
    }
    let tail = source[startRange.lowerBound...]
    guard let openBraceRange = tail.range(of: "{") else {
      XCTFail("`private func \(name)` opening brace missing.")
      return ""
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
    XCTFail("`private func \(name)` body did not close.")
    return ""
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
