import Foundation
import XCTest

final class SessionCockpitHeaderAccessibilityContractTests: XCTestCase {
  func testHeaderCardUsesAccessibilityProbeNotPropagatingIdentifier() throws {
    let source = try cockpitHeaderSource()
    let body = try extractBody(of: "var body: some View", in: source)

    XCTAssertFalse(
      body.contains(".accessibilityIdentifier(HarnessMonitorAccessibility.sessionHeaderCard)"),
      """
      SessionCockpitHeaderCard.body must not call \
      `.accessibilityIdentifier(.sessionHeaderCard)` on the outer container. The modifier \
      propagates to every child accessibility element on macOS, shadowing the distinct \
      identifiers on `observeSessionButton`, `endSessionButton`, and the observe summary \
      card so XCUITest queries by those identifiers no longer resolve.
      """
    )

    XCTAssertTrue(
      body.contains(".accessibilityTestProbe(HarnessMonitorAccessibility.sessionHeaderCard)"),
      """
      SessionCockpitHeaderCard.body must mark the header with \
      `.accessibilityTestProbe(.sessionHeaderCard)` so an isolated overlay element carries \
      the identifier in tests without overwriting child identifiers.
      """
    )
  }

  private func cockpitHeaderSource() throws -> String {
    try String(
      contentsOf: repoRoot().appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/SessionCockpitHeaderCard.swift"
      ),
      encoding: .utf8
    )
  }

  private func extractBody(of declaration: String, in source: String) throws -> String {
    guard let startRange = source.range(of: declaration) else {
      throw XCTSkip("declaration `\(declaration)` not found in source")
    }
    let tail = source[startRange.lowerBound...]
    guard let openBraceRange = tail.range(of: "{") else {
      throw XCTSkip("declaration opening brace missing")
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
    throw XCTSkip("declaration body did not close")
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
