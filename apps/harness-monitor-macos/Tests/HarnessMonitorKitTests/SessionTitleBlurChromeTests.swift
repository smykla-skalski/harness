import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class SessionTitleBlurChromeTests: XCTestCase {
  func testStatusPaletteMatchesLegacyChrome() {
    XCTAssertEqual(
      configuration(status: .awaitingLeader).assetName,
      "HarnessMonitorAccent"
    )
    XCTAssertEqual(
      configuration(status: .active).assetName,
      "HarnessMonitorSuccess"
    )
    XCTAssertEqual(
      configuration(status: .paused).assetName,
      "HarnessMonitorCaution"
    )
    XCTAssertEqual(
      configuration(status: .leaderlessDegraded).assetName,
      "HarnessMonitorCaution"
    )
    XCTAssertEqual(
      configuration(status: .ended).assetName,
      "HarnessMonitorInk"
    )
  }

  func testStaleSessionUsesNeutralTitlebarTone() {
    let stale = configuration(status: .active, isStale: true)

    XCTAssertEqual(stale.tone, .idle)
    XCTAssertEqual(stale.assetName, "HarnessMonitorInk")
  }

  func testGeometryAndAnimationConstantsStayStable() {
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.height, 160)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.titleLeadingPadding, 320)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.titleVerticalOffset, 56)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.blurWidth, 280)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.blurHeight, 96)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.blurRadius, 56)
    XCTAssertEqual(SessionTitleBlurChromeConfiguration.tintOpacity, 0.30)
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
    XCTAssertTrue(source.contains(".blur(radius:"))
    XCTAssertFalse(source.contains("Circle()"))
    XCTAssertFalse(source.contains("RadialGradient("))
    XCTAssertFalse(source.contains("import AppKit"))
    XCTAssertFalse(source.contains("NSViewRepresentable"))
    XCTAssertFalse(source.contains("NSVisualEffectView"))
  }

  func testSessionWindowAttachesTitleBlurChromeAtNavigationSurface() throws {
    let source = try sourceFile(named: "SessionWindowView+Presentation.swift")

    XCTAssertTrue(source.contains(".navigationTitle(navigationTitleText)"))
    XCTAssertTrue(source.contains(".navigationSubtitle(navigationSubtitleText)"))
    XCTAssertTrue(source.contains(".sessionTitleBlurChrome("))
    XCTAssertTrue(source.contains("status: summary?.status ?? .awaitingLeader"))
    XCTAssertTrue(source.contains("isStale: snapshot == nil"))
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
