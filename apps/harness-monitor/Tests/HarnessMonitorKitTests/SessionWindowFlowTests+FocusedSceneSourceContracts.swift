import Testing

extension SessionWindowFlowTests {
  @Test("Dashboard and scene focus publishers use the deferred helper")
  func dashboardAndSceneFocusPublishersUseDeferredHelperSourceContract() throws {
    let reviewsRouteSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardReviewsRouteView.swift"
    )
    let reviewsSearchSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardReviewsRouteView+ToolbarSearch.swift"
    )
    let policyCanvasSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )
    let auditTimelineSource = try harnessSourceFile(
      named: "App/HarnessMonitorAppSceneSupport+AuditTimeline.swift"
    )

    #expect(reviewsRouteSource.contains(".harnessFocusedSceneValue(\\.dashboardReviewsCommands"))
    #expect(!reviewsRouteSource.contains(".focusedSceneValue(\\.dashboardReviewsCommands"))
    #expect(
      reviewsSearchSource.contains(
        ".harnessFocusedSceneValue(\\.harnessSidebarSearchFocusAction"
      )
    )
    #expect(
      !reviewsSearchSource.contains(
        ".focusedSceneValue(\\.harnessSidebarSearchFocusAction"
      )
    )
    #expect(policyCanvasSource.contains(".harnessFocusedSceneValue("))
    #expect(policyCanvasSource.contains("\\.harnessPolicyCanvasZoomFocus"))
    #expect(policyCanvasSource.contains("sceneFocusEnabled ? zoomFocus : nil"))
    #expect(!policyCanvasSource.contains(".focusedSceneValue(\\.harnessPolicyCanvasZoomFocus"))
    #expect(auditTimelineSource.contains(".harnessFocusedSceneValue("))
    #expect(!auditTimelineSource.contains(".focusedSceneValue("))
  }
}
