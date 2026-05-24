import AppKit
import SwiftUI
import XCTest

@testable import HarnessMonitorUIPreviewable

@MainActor
final class SessionSidebarRowMetricsTests: XCTestCase {
  func testDefaultFontScaleKeepsRowsCompact() {
    let metrics = SessionSidebarRowMetrics(fontScale: 1.0)

    XCTAssertEqual(metrics.minHeight, 28)
    XCTAssertEqual(metrics.severityIndicatorSize, 8)
    XCTAssertEqual(metrics.severityIndicatorOffset, 4)
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
    XCTAssertGreaterThan(
      metrics.iconColumnWidth,
      SessionSidebarRowMetrics(fontScale: 1.0).iconColumnWidth
    )
    XCTAssertGreaterThan(
      metrics.severityIndicatorSize,
      SessionSidebarRowMetrics(fontScale: 1.0).severityIndicatorSize
    )
    XCTAssertGreaterThan(
      metrics.severityIndicatorOffset,
      SessionSidebarRowMetrics(fontScale: 1.0).severityIndicatorOffset
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

  func testSelectedSidebarListRowShrinksBelowThePreviousSidebarFloorForSmallText() {
    let compactSelectedRowHeight = selectedRowHeightInList(textSizeIndex: 0)
    let largestSelectedRowHeight = selectedRowHeightInList(
      textSizeIndex: HarnessMonitorTextSize.scales.count - 1
    )

    XCTAssertLessThan(compactSelectedRowHeight, 40)
    XCTAssertLessThan(compactSelectedRowHeight, largestSelectedRowHeight)
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

  private func selectedRowHeightInList(textSizeIndex: Int) -> CGFloat {
    let host = NSHostingView(
      rootView: AnyView(
        SessionSidebarRowSelectionPreviewContent(
          selection: .constant(.route(.overview))
        )
        .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
        .environment(\.controlActiveState, .key)
      )
    )
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 260, height: 220),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = CGRect(x: 0, y: 0, width: 260, height: 220)
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    attachWindowSizedSnapshot(
      for: host,
      named: "session-sidebar-list-text-size-\(textSizeIndex)"
    )

    guard let tableView = firstDescendant(in: host, as: NSTableView.self) else {
      XCTFail("Expected SessionSidebar list preview to bridge to NSTableView")
      return 0
    }

    guard tableView.selectedRow >= 0 else {
      XCTFail("Expected SessionSidebar list preview to have a selected row")
      return 0
    }

    return tableView.rect(ofRow: tableView.selectedRow).height
  }

  private func attachWindowSizedSnapshot(
    for host: NSHostingView<AnyView>,
    named name: String
  ) {
    let bounds = host.bounds
    guard
      !bounds.isEmpty,
      let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds)
    else {
      XCTFail("Expected SessionSidebar list preview host to produce a bitmap snapshot")
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

  private func firstDescendant<ViewType: NSView>(
    in root: NSView,
    as type: ViewType.Type
  ) -> ViewType? {
    if let view = root as? ViewType {
      return view
    }

    for subview in root.subviews {
      if let match = firstDescendant(in: subview, as: type) {
        return match
      }
    }

    return nil
  }
}
