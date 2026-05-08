import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session content-detail split layout")
struct SessionContentDetailSplitLayoutTests {
  @Test("Wide layouts keep the intended content/detail floor widths")
  func wideLayoutsKeepComfortableFloorWidths() {
    let range = SessionContentDetailSplitLayout.contentWidthRange(availableWidth: 1200)

    #expect(range.lowerBound == 280)
    #expect(range.upperBound == 879)
  }

  @Test("Stored widths clamp into the current container range")
  func storedWidthsClampIntoCurrentContainerRange() {
    #expect(
      SessionContentDetailSplitLayout.clampedContentWidth(
        preferredWidth: 120,
        availableWidth: 1200
      ) == 280
    )
    #expect(
      SessionContentDetailSplitLayout.clampedContentWidth(
        preferredWidth: 1600,
        availableWidth: 1200
      ) == 879
    )
  }

  @Test("Narrow layouts keep both panes visible")
  func narrowLayoutsKeepBothPanesVisible() {
    let contentWidth = SessionContentDetailSplitLayout.clampedContentWidth(
      preferredWidth: SessionContentDetailSplitLayout.defaultContentWidth,
      availableWidth: 500
    )
    let detailWidth =
      500 - CGFloat(contentWidth) - SessionContentDetailSplitLayout.dividerWidth

    #expect(contentWidth >= SessionContentDetailSplitLayout.minimumVisibleColumnWidth)
    #expect(detailWidth >= SessionContentDetailSplitLayout.minimumVisibleColumnWidth)
  }
}
