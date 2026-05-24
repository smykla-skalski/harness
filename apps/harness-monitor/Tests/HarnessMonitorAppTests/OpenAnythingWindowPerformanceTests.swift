import Foundation
import XCTest

final class OpenAnythingWindowPerformanceTests: XCTestCase {
  func testPresentationUsesMeasuredContentHeightBeforeFittingFallback() throws {
    let source = try harnessSourceFile(named: "App/OpenAnythingPaletteWindow.swift")
    let showSource = try sourceBlock(
      startingWith: "  func show(scope: OpenAnythingDomain?, restoreLastQuery: Bool) {",
      endingBefore: "\n  func hide(",
      in: source
    )

    XCTAssertTrue(source.contains("private var lastMeasuredContentHeight: CGFloat?"))
    XCTAssertTrue(source.contains("private func sizePanelForPresentation"))
    XCTAssertTrue(source.contains("if let lastMeasuredContentHeight"))
    XCTAssertTrue(source.contains("lastMeasuredContentHeight = clampedHeight"))
    XCTAssertTrue(showSource.contains("sizePanelForPresentation(panel)"))
    XCTAssertFalse(showSource.contains("sizePanelToFittingContent(panel)"))
  }

  private func harnessSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitor")
      .appendingPathComponent(relativePath)
  }

  private func sourceBlock(
    startingWith startMarker: String,
    endingBefore endMarker: String,
    in source: String
  ) throws -> Substring {
    let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
    let suffix = source[start...]
    let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
    return suffix[..<end]
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
