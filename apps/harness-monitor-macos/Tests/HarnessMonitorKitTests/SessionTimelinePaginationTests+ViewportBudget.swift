import Testing

@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Timeline window budget grows with viewport capacity")
  func timelineWindowBudgetGrowsWithViewportCapacity() {
    #expect(
      SessionTimelineWindowBudget.limit(forViewportRowCapacity: 4)
        == SessionTimelineWindowNavigation.defaultLimit
    )
    #expect(
      SessionTimelineWindowBudget.limit(forViewportRowCapacity: 30)
        == 30 + SessionTimelineScrollBoundaryState.triggerBufferRowCount
    )
    #expect(
      SessionTimelineWindowBudget.limit(forViewportRowCapacity: 500)
        == SessionTimelineWindowBudget.maximumLimit
    )
  }
}
