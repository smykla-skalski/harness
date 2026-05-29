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

@Suite("Dashboard review conversation visibility window")
struct DashboardReviewConversationVisibilityWindowTests {
  @Test("small collections stay contiguous without a separate oldest anchor")
  func smallCollectionsStayContiguousWithoutASeparateOldestAnchor() {
    let window = DashboardReviewConversationVisibilityWindow(
      totalRowsCount: 17,
      leadingVisibleRowsLimit: 16,
      batchSize: 16,
      trailingAnchorCount: 1
    )

    #expect(window.leadingVisibleRowsCount == 17)
    #expect(window.trailingVisibleRowsCount == 0)
    #expect(window.hiddenMiddleRowCount == 0)
    #expect(window.nextExpansionCount == 0)
    #expect(window.visibleRowsCount == 17)
  }

  @Test("large collections preserve a single oldest anchor and hide the middle")
  func largeCollectionsPreserveASingleOldestAnchorAndHideTheMiddle() {
    let window = DashboardReviewConversationVisibilityWindow(
      totalRowsCount: 40,
      leadingVisibleRowsLimit: 16,
      batchSize: 16,
      trailingAnchorCount: 1
    )

    #expect(window.leadingVisibleRowsCount == 16)
    #expect(window.trailingVisibleRowsCount == 1)
    #expect(window.hiddenMiddleRowCount == 23)
    #expect(window.nextExpansionCount == 16)
    #expect(window.visibleRowsCount == 17)
  }

  @Test("next expansion size clamps to the remaining hidden middle rows")
  func nextExpansionSizeClampsToTheRemainingHiddenMiddleRows() {
    let window = DashboardReviewConversationVisibilityWindow(
      totalRowsCount: 34,
      leadingVisibleRowsLimit: 32,
      batchSize: 16,
      trailingAnchorCount: 1
    )

    #expect(window.leadingVisibleRowsCount == 32)
    #expect(window.trailingVisibleRowsCount == 1)
    #expect(window.hiddenMiddleRowCount == 1)
    #expect(window.nextExpansionCount == 1)
    #expect(window.visibleRowsCount == 33)
  }
}

@Suite("Dashboard review conversation gap action")
struct DashboardReviewConversationGapActionTests {
  @Test("show action uses show-more copy")
  func showActionUsesShowMoreCopy() {
    let action = DashboardReviewConversationCollapsedGapAction.show(16)

    #expect(action.title == "Show 16 more events")
    #expect(action.helpText == "Render the next batch of hidden review activity")
  }

  @Test("hide action uses hide copy")
  func hideActionUsesHideCopy() {
    let action = DashboardReviewConversationCollapsedGapAction.hide(23)

    #expect(action.title == "Hide 23 events")
    #expect(action.helpText == "Hide the events revealed from the collapsed middle")
  }
}
