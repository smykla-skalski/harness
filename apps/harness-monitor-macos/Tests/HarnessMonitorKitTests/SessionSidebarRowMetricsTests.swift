import AppKit
import SwiftUI
import XCTest

@testable import HarnessMonitorUIPreviewable

@MainActor
final class SessionSidebarRowMetricsTests: XCTestCase {
  func testDefaultFontScaleKeepsRowsCompact() {
    let metrics = SessionSidebarRowMetrics(fontScale: 1.0)

    XCTAssertEqual(metrics.minHeight, 28)
    XCTAssertEqual(metrics.multiSelectControlSize, 24)
    XCTAssertEqual(metrics.dragHandleHitTarget, 24)
    XCTAssertEqual(metrics.severityIndicatorSize, 8)
    XCTAssertEqual(
      fittedHeight(for: 1.0),
      metrics.minHeight,
      accuracy: 0.5
    )
  }

  func testLargeFontScaleUsesRowFloorWithoutDoubleCountingVerticalPadding() {
    let metrics = SessionSidebarRowMetrics(fontScale: 1.8)
    let fittedHeight = fittedHeight(for: 1.8)

    XCTAssertGreaterThanOrEqual(metrics.minHeight, 44)
    XCTAssertGreaterThanOrEqual(metrics.multiSelectControlSize, 44)
    XCTAssertGreaterThanOrEqual(metrics.dragHandleHitTarget, 44)
    XCTAssertGreaterThan(
      metrics.iconColumnWidth,
      SessionSidebarRowMetrics(fontScale: 1.0).iconColumnWidth
    )
    XCTAssertGreaterThan(
      metrics.severityIndicatorSize,
      SessionSidebarRowMetrics(fontScale: 1.0).severityIndicatorSize
    )
    XCTAssertEqual(fittedHeight, metrics.minHeight, accuracy: 0.5)
    XCTAssertLessThan(
      fittedHeight,
      metrics.minHeight + metrics.verticalPadding * 2
    )
  }

  func testFontScaleClampsExtremeValues() {
    XCTAssertEqual(
      SessionSidebarRowMetrics(fontScale: 0.1),
      SessionSidebarRowMetrics(fontScale: 0.85)
    )
    XCTAssertEqual(
      SessionSidebarRowMetrics(fontScale: 9.0),
      SessionSidebarRowMetrics(fontScale: 1.8)
    )
  }

  private func fittedHeight(for scale: CGFloat) -> CGFloat {
    let host = hostingView(for: scale)
    attachSnapshot(for: host, named: "session-sidebar-row-scale-\(scale)")
    return host.fittingSize.height
  }

  private func hostingView(for scale: CGFloat) -> NSHostingView<AnyView> {
    let host = NSHostingView(
      rootView: AnyView(
        SessionSidebarRowPreviewContent()
          .environment(\.fontScale, scale)
      )
    )
    host.frame = CGRect(x: 0, y: 0, width: 260, height: 120)
    host.layoutSubtreeIfNeeded()
    return host
  }

  private func attachSnapshot(for host: NSHostingView<AnyView>, named name: String) {
    let size = host.fittingSize
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()

    let bounds = host.bounds
    guard
      let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds)
    else {
      XCTFail("Expected SessionSidebarRow preview host to produce a bitmap snapshot")
      return
    }
    host.cacheDisplay(in: bounds, to: bitmap)

    let image = NSImage(size: bounds.size)
    image.addRepresentation(bitmap)

    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
