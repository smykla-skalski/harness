import Foundation
import XCTest

final class SwarmFullFlowContractTests: XCTestCase {
  func testBuildForTestingSchemeMatchesProjectAndXctestrunContract() throws {
    let repoRoot = repoRoot()
    let project = try String(
      contentsOf: repoRoot.appendingPathComponent("apps/harness-monitor-macos/Project.swift"),
      encoding: .utf8
    )
    let orchestrator = try String(
      contentsOf: repoRoot.appendingPathComponent(
        "apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift"
      ),
      encoding: .utf8
    )

    let projectScheme = try extractFirstCapture(
      in: project,
      pattern: #"private let agentsE2EScheme: Scheme = \.scheme\(\s*name: "([^"]+)""#,
      description: "agents e2e shared scheme"
    )
    let buildForTestingScheme = try extractFirstCapture(
      in: orchestrator,
      pattern: #""-scheme", "([^"]+)""#,
      description: "swarm build-for-testing scheme"
    )
    let xctestrunPrefix = try extractFirstCapture(
      in: orchestrator,
      pattern: #"hasPrefix\("([^"]+)_"\)"#,
      description: "generated xctestrun prefix"
    )

    XCTAssertEqual(
      buildForTestingScheme,
      projectScheme,
      "swarm full-flow must build-for-testing with the shared scheme exported by Project.swift"
    )
    XCTAssertEqual(
      buildForTestingScheme,
      xctestrunPrefix,
      "swarm full-flow must search for an xctestrun emitted by the same scheme it builds"
    )
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

  private func extractFirstCapture(
    in text: String,
    pattern: String,
    description: String
  ) throws -> String {
    let expression = try XCTUnwrap(
      try? NSRegularExpression(
        pattern: pattern,
        options: [.dotMatchesLineSeparators]
      ),
      "invalid regex for \(description)"
    )
    let range = NSRange(text.startIndex..., in: text)
    let match = try XCTUnwrap(
      expression.firstMatch(in: text, options: [], range: range),
      "missing \(description)"
    )
    let captureRange = try XCTUnwrap(
      Range(match.range(at: 1), in: text),
      "missing capture for \(description)"
    )
    return String(text[captureRange])
  }
}
