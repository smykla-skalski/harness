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
}
