import Foundation
import Testing

@Suite("Dashboard reviews detail UX contracts")
struct DashboardReviewsDetailUXContractTests {
  @Test("Reviews detail hides the visual split divider and uses a wider detail width")
  func reviewsDetailHidesSplitDividerAndUsesWiderWidth() throws {
    let route = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsRouteView.swift"
    )
    let helpers = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsRouteView+DetailHelpers.swift"
    )
    let split = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(route.contains("showsDividerLine: false"))
    #expect(helpers.contains("let reviewsDetailMaxWidth: CGFloat = 1_180"))
    #expect(split.contains("showsDividerLine: Bool = true"))
    #expect(split.contains("if !showsDividerLine, !isKeyboardFocused, !isHovered, !isDragging"))
  }

  @Test("Detail surface and header share the same window background")
  func detailSurfaceAndHeaderShareWindowBackground() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )

    #expect(detail.contains("DashboardReviewDetailHeader(item: item)"))
    #expect(detail.contains(".background(Color(nsColor: .windowBackgroundColor))"))
    #expect(detail.contains("DashboardReviewAttentionSummary(item: item)"))
    #expect(!detail.contains("DashboardReviewProvenanceMiniBar"))
  }

  @Test("Header actions stay in one horizontal command row")
  func headerActionsStayInOneHorizontalCommandRow() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains("ScrollView(.horizontal)"))
    #expect(actionBar.contains("HStack(spacing: HarnessMonitorTheme.itemSpacing)"))
    #expect(!actionBar.contains("HarnessMonitorWrapLayout("))
    #expect(actionBar.contains("\"Open pull request\""))
  }

  @Test("Status summary explains policy blocks instead of piling up ambiguous chips")
  func statusSummaryExplainsPolicyBlocks() throws {
    let visuals = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsVisualComponents.swift"
    )

    #expect(visuals.contains("Text(item.statusSentence)"))
    #expect(visuals.contains("DashboardReviewAttentionSummary"))
    #expect(visuals.contains("\"Policy blocked\""))
    #expect(visuals.contains("\"review policy is blocking merge\""))
    #expect(visuals.contains("Text(\"Files\")"))
    #expect(!visuals.contains("\"Policy wait\""))
  }

  @Test("Description and file controls expose editable state with clear labels")
  func descriptionAndFileControlsExposeEditableState() throws {
    let description = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsSupportingViews.swift"
    )
    let markdown = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Shared/HarnessMonitorMarkdownText.swift"
    )
    let header = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesHeader.swift"
    )
    let fileCard = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFileCard.swift"
    )

    #expect(description.contains("Task-list checkboxes update the pull request description."))
    #expect(markdown.contains(".controlSize(.regular)"))
    #expect(markdown.contains("Toggle pull request task-list item"))
    #expect(header.contains("visible of"))
    #expect(header.contains("\"Hide generated files\""))
    #expect(header.contains("\"Hide whitespace-only\""))
    #expect(fileCard.contains("Toggle(\n        \"Viewed\""))
    #expect(fileCard.contains("Label(viewMode.label, systemImage: \"rectangle.split.2x1\")"))
  }

  @Test("Checks Activity and Reviews sections reduce repetition by default")
  func lowerSectionsReduceRepetitionByDefault() throws {
    let checks = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewCheckList.swift"
    )
    let activity = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActivity.swift"
    )
    let reviews = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsReviewLabelLists.swift"
    )

    #expect(checks.contains("DashboardReviewPassingChecksSummary"))
    #expect(checks.contains("\"Show passing checks\""))
    #expect(activity.contains("\"No monitor action has run for this pull request.\""))
    #expect(activity.contains("\"Copy diagnostics\""))
    #expect(!activity.contains("\"Copy action diagnostics\""))
    #expect(reviews.contains("DashboardReviewReviewerPill"))
    #expect(reviews.contains("\"approval\""))
  }

  private func source(_ appLocalPath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = appRoot.appendingPathComponent(appLocalPath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
