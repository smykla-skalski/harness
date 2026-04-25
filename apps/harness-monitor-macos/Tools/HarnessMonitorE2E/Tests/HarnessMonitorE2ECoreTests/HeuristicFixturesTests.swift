import XCTest

@testable import HarnessMonitorE2ECore

final class HeuristicFixturesTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("heuristic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  func testKnownCodeAppendsValidJsonl() throws {
    let log = tempDir.appendingPathComponent("raw.jsonl")
    try HeuristicFixtures.append(code: "python_traceback_output", to: log)
    let body = try String(contentsOf: log, encoding: .utf8)
    let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
    XCTAssertEqual(lines.count, 2)
    for line in lines {
      let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      XCTAssertNotNil(json?["timestamp"])
      XCTAssertNotNil(json?["message"])
    }
  }

  func testRepeatedAppendIsAdditive() throws {
    let log = tempDir.appendingPathComponent("raw.jsonl")
    try HeuristicFixtures.append(code: "agent_repeated_error", to: log)
    try HeuristicFixtures.append(code: "agent_repeated_error", to: log)
    let body = try String(contentsOf: log, encoding: .utf8)
    XCTAssertEqual(
      body.split(separator: "\n", omittingEmptySubsequences: true).count,
      4
    )
  }

  func testUnknownCodeThrows() {
    let log = tempDir.appendingPathComponent("raw.jsonl")
    XCTAssertThrowsError(try HeuristicFixtures.append(code: "no-such-code", to: log)) { error in
      guard case HeuristicFixtures.Failure.unknownCode = error else {
        XCTFail("expected unknownCode, got \(error)")
        return
      }
    }
  }

  func testCatalogCoversAllExpectedCodes() {
    let expected: Set<String> = [
      "python_traceback_output",
      "unauthorized_git_commit_during_run",
      "python_used_in_bash_tool_use",
      "absolute_manifest_path_used",
      "jq_error_in_command_output",
      "unverified_recursive_remove",
      "hook_denied_tool_call",
      "agent_repeated_error",
      "agent_stalled_progress",
      "cross_agent_file_conflict",
    ]
    XCTAssertEqual(Set(HeuristicFixtures.catalog.keys), expected)
  }
}
