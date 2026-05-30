import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension ToolCallTimelineViewTests {
  @Test("Viewport-visible rows intersect visible rect")
  func viewportVisibleRowsIntersectVisibleRect() {
    let visible = ToolCallTimelineView.viewportVisibleRowIDs(
      renderedRowIDs: ["row-1", "row-2", "row-3"],
      rowFrames: [
        "row-1": CGRect(x: 0, y: 10, width: 100, height: 30),
        "row-2": CGRect(x: 0, y: 120, width: 100, height: 30),
        "row-3": CGRect(x: 0, y: 260, width: 100, height: 30),
      ],
      visibleRect: CGRect(x: 0, y: 100, width: 500, height: 80)
    )

    #expect(visible == ["row-2"])
  }

  @Test("Viewport-visible rows ignore missing and non-rendered frame entries")
  func viewportVisibleRowsIgnoreMissingAndNonRenderedFrames() {
    let visible = ToolCallTimelineView.viewportVisibleRowIDs(
      renderedRowIDs: ["row-a", "row-b"],
      rowFrames: [
        "row-a": CGRect(x: 0, y: 10, width: 100, height: 30),
        "row-c": CGRect(x: 0, y: 20, width: 100, height: 30),
      ],
      visibleRect: CGRect(x: 0, y: 0, width: 500, height: 50)
    )

    #expect(visible == ["row-a"])
  }

  @Test("Virtualized scroll bucket ignores sub-row scroll changes")
  func virtualizedScrollBucketIgnoresSubRowScrollChanges() {
    let nearStart = ToolCallTimelineScrollMetrics(
      contentOffsetY: 100,
      viewportHeight: 260,
      visibleRect: CGRect(x: 0, y: 100, width: 500, height: 260)
    )
    let nearEnd = ToolCallTimelineScrollMetrics(
      contentOffsetY: 125,
      viewportHeight: 260,
      visibleRect: CGRect(x: 0, y: 125, width: 500, height: 260)
    )

    #expect(
      ToolCallTimelineVirtualizedLayout.scrollBucket(for: nearStart)
        == ToolCallTimelineVirtualizedLayout.scrollBucket(for: nearEnd)
    )
  }

  @Test("Virtualized scroll bucket advances once the next row window is reached")
  func virtualizedScrollBucketAdvancesAtRowBoundary() {
    let beforeBoundary = ToolCallTimelineScrollMetrics(
      contentOffsetY: 100,
      viewportHeight: 260,
      visibleRect: CGRect(x: 0, y: 100, width: 500, height: 260)
    )
    let afterBoundary = ToolCallTimelineScrollMetrics(
      contentOffsetY: 154,
      viewportHeight: 260,
      visibleRect: CGRect(x: 0, y: 154, width: 500, height: 260)
    )

    #expect(
      ToolCallTimelineVirtualizedLayout.scrollBucket(for: beforeBoundary)
        != ToolCallTimelineVirtualizedLayout.scrollBucket(for: afterBoundary)
    )
  }

  @Test("Virtualized layout stays stable for sub-row scroll movement")
  func virtualizedLayoutStaysStableForSubRowScrollMovement() {
    let presentation = ToolCallTimelineView.materialisePresentation(
      from: (0..<40).map { index in
        makeAnnotatedToolCallEntry(
          entryId: "call-\(index)",
          recordedAt: String(format: "2026-04-28T00:00:%02dZ", index % 60),
          status: "completed",
          stopReason: "end_turn",
          sequence: UInt64(index)
        )
      }
    )
    let nearStart = ToolCallTimelineVirtualizedLayout(
      presentation: presentation,
      scrollMetrics: ToolCallTimelineScrollMetrics(
        contentOffsetY: 100,
        viewportHeight: 260,
        visibleRect: CGRect(x: 0, y: 100, width: 500, height: 260)
      )
    )
    let nearEnd = ToolCallTimelineVirtualizedLayout(
      presentation: presentation,
      scrollMetrics: ToolCallTimelineScrollMetrics(
        contentOffsetY: 125,
        viewportHeight: 260,
        visibleRect: CGRect(x: 0, y: 125, width: 500, height: 260)
      )
    )

    #expect(nearStart == nearEnd)
  }
}
