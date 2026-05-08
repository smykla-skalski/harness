import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class SessionTitleBlurChromeTests: XCTestCase {
  func testStatusPaletteMatchesChunkSevenContract() {
    XCTAssertEqual(
      configuration(status: .awaitingLeader).tone,
      .idle
    )
    XCTAssertEqual(
      configuration(status: .active).assetName,
      "HarnessMonitorAccent"
    )
    XCTAssertEqual(
      configuration(status: .leaderlessDegraded).assetName,
      "HarnessMonitorCaution"
    )
    XCTAssertEqual(
      configuration(status: .ended).assetName,
      "HarnessMonitorSuccess"
    )
  }

  func testStaleSessionUsesNeutralTitlebarTone() {
    let stale = configuration(status: .active, isStale: true)

    XCTAssertEqual(stale.tone, .idle)
    XCTAssertEqual(stale.assetName, "HarnessMonitorInk")
  }

  func testGeometryAndAnimationConstantsStayStable() {
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.height, 96)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.gradientRadius, 360)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.titleLeadingPadding, 78)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.tintOpacity, 0.18)
    XCTAssertEqual(
      SessionTitleBlurChromeConfiguration.reducedTransparencyOpacity,
      0.82
    )
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.animationDuration, 0.18)
    XCTAssertEqual(
      SessionTitleBlurChromeConfiguration.accessibilityIdentifier,
      "harness.session.title-blur-chrome"
    )
  }

  func testTitleBlurChromeStaysNativeSwiftUI() throws {
    let source = try sourceFile(named: "SessionTitleBlurChrome.swift")

    XCTAssertTrue(source.contains("import SwiftUI"))
    XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceTransparency)"))
    XCTAssertTrue(source.contains("RadialGradient("))
    XCTAssertFalse(source.contains("import AppKit"))
    XCTAssertFalse(source.contains("NSViewRepresentable"))
    XCTAssertFalse(source.contains("NSVisualEffectView"))
  }

  private func configuration(
    status: SessionStatus,
    isStale: Bool = false
  ) -> SessionTitleBlurChromeConfiguration {
    SessionTitleBlurChromeConfiguration(
      status: status,
      isStale: isStale,
      reduceTransparency: false
    )
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
