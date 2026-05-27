import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review conversation count summary")
struct DashboardReviewConversationCountSummaryTests {
  @Test("Status label follows rendered timeline rows")
  func statusLabelFollowsRenderedTimelineRows() {
    let summary = DashboardReviewConversationCountSummary(
      visibleRowsCount: 9,
      totalRowsCount: 9,
      hasOlder: false
    )

    #expect(summary.statusLabel == "9 events")
  }

  @Test("Footer shows all rendered rows when every row is visible")
  func footerShowsAllRenderedRowsWhenEveryRowIsVisible() {
    let summary = DashboardReviewConversationCountSummary(
      visibleRowsCount: 9,
      totalRowsCount: 9,
      hasOlder: false
    )

    #expect(summary.footerLabel == "9 events")
    #expect(summary.footerAccessibilityLabel == "Showing all 9 events")
  }

  @Test("Footer keeps the visible-of-total copy for local batching")
  func footerKeepsVisibleOfTotalCopyForLocalBatching() {
    let summary = DashboardReviewConversationCountSummary(
      visibleRowsCount: 16,
      totalRowsCount: 22,
      hasOlder: false
    )

    #expect(summary.footerLabel == "Showing 16 of 22 events")
    #expect(summary.footerAccessibilityLabel == "Showing 16 of 22 events")
  }

  @Test("Footer more-available copy uses rendered rows, not raw entries")
  func footerMoreAvailableCopyUsesRenderedRows() {
    let summary = DashboardReviewConversationCountSummary(
      visibleRowsCount: 9,
      totalRowsCount: 9,
      hasOlder: true
    )

    #expect(summary.footerLabel == "Showing 9 (more available)")
    #expect(summary.footerAccessibilityLabel == "Showing 9 events, more available")
  }
}
