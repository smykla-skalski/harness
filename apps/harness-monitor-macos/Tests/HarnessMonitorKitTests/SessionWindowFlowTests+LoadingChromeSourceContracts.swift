import Testing

extension SessionWindowFlowTests {
  @Test("Session loading chrome avoids indeterminate progress churn")
  func sessionLoadingChromeAvoidsIndeterminateProgressChurn() throws {
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let bannerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionBannerStack.swift"
    )

    #expect(columnsSource.contains("Label(\"Loading session\", systemImage: \"hourglass\")"))
    #expect(!columnsSource.contains("ProgressView(\"Loading session\")"))
    #expect(bannerSource.contains("Image(systemName: \"hourglass\")"))
    #expect(!bannerSource.contains("ProgressView()"))
  }

  @Test("Shared loading chrome avoids continuous animation churn")
  func sharedLoadingChromeAvoidsContinuousAnimationChurn() throws {
    let spinnerSource = try previewableSourceFile(
      named: "Views/Shared/HarnessMonitorSpinner.swift"
    )
    let timelineSource = try previewableSourceFile(
      named: "Views/Timeline/SessionTimelineList.swift"
    )
    let connectionSource = try previewableSourceFile(named: "Views/App/ConnectionViews.swift")
    let inlineActionSource = try previewableSourceFile(
      named: "Views/Shared/HarnessInlineActionButton.swift"
    )
    let asyncActionSource = try previewableSourceFile(
      named: "Views/Shared/HarnessMonitorActionControls.swift"
    )
    let headerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionCockpitHeaderCard.swift"
    )

    #expect(spinnerSource.contains("Image(systemName: \"hourglass\")"))
    #expect(!spinnerSource.contains("TimelineView"))
    #expect(!spinnerSource.contains("rotationEffect"))
    #expect(timelineSource.contains("HarnessMonitorSpinner(size: 14)"))
    #expect(!timelineSource.contains("ProgressView()"))
    #expect(connectionSource.contains("HarnessMonitorSpinner(size: 14)"))
    #expect(!inlineActionSource.contains(".transition(.opacity)"))
    #expect(!asyncActionSource.contains(".transition(.opacity)"))
    #expect(!headerSource.contains(".transition(.opacity)"))
  }
}
