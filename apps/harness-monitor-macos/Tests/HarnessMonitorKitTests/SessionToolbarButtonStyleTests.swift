import XCTest

@testable import HarnessMonitorUIPreviewable

final class SessionToolbarButtonStyleTests: XCTestCase {
  func testToolbarChromeMetricsMatchSessionWindowContract() {
    XCTAssertEqual(SessionToolbarButtonStyle.Metrics.cornerRadius, 8)
    XCTAssertEqual(SessionToolbarButtonStyle.Metrics.horizontalPadding, 10)
    XCTAssertEqual(SessionToolbarButtonStyle.Metrics.verticalPadding, 5)
    XCTAssertEqual(SessionToolbarButtonStyle.Metrics.minHeight, 28)
    XCTAssertEqual(SessionToolbarButtonStyle.Metrics.iconWidth, 16)
    XCTAssertEqual(SessionToolbarButtonStyle.Metrics.pressedScale, 0.98)
    XCTAssertEqual(SessionToolbarButtonStyle.Metrics.animationDuration, 0.14)
  }

  func testToolbarChromeMetricsScaleWithFontSetting() {
    let defaultMetrics = SessionToolbarButtonStyle.Metrics.resolved(fontScale: 1.0)
    let largeMetrics = SessionToolbarButtonStyle.Metrics.resolved(fontScale: 1.8)

    XCTAssertEqual(defaultMetrics.minHeight, 28)
    XCTAssertGreaterThanOrEqual(largeMetrics.minHeight, 44)
    XCTAssertGreaterThan(largeMetrics.horizontalPadding, defaultMetrics.horizontalPadding)
    XCTAssertGreaterThan(largeMetrics.iconWidth, defaultMetrics.iconWidth)
  }

  func testToolbarStyleFilesStayWithinPlanCaps() throws {
    let styleSource = try sourceFile(named: "SessionToolbarButtonStyle.swift")
    let bodySource = try sourceFile(named: "SessionToolbarButtonStyleBody.swift")

    XCTAssertLessThanOrEqual(styleSource.split(separator: "\n").count, 120)
    XCTAssertLessThanOrEqual(bodySource.split(separator: "\n").count, 120)
    XCTAssertTrue(styleSource.contains("SessionToolbarButtonStyleBody("))
    XCTAssertTrue(bodySource.contains("accessibilityReduceMotion"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
