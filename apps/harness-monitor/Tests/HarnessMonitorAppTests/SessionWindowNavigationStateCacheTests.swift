import XCTest

@MainActor
final class SessionWindowNavigationStateCacheTests: XCTestCase {
  func testSessionWindowReusesNavigationHandlersAcrossBodyEvaluations() throws {
    let source = try sessionWindowSource()

    XCTAssertTrue(source.contains("@State private var navigationStateStorage"))
    XCTAssertTrue(source.contains("navigationStateStorage.updating("))
    XCTAssertTrue(source.contains("navigationStateStorage.setHandlers("))
    XCTAssertFalse(source.contains("let navigationState = WindowNavigationState("))
  }

  private func sessionWindowSource() throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repoRoot
        .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
        .appendingPathComponent("Views/Sessions/SessionWindowView.swift"),
      encoding: .utf8
    )
  }
}
