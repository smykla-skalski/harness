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
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewsRouteView+DetailHelpers.swift"
    )
    let split = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(route.contains("showsDividerLine: false"))
    #expect(helpers.contains("let reviewsDetailMaxWidth: CGFloat = 1_180"))
    #expect(split.contains("showsDividerLine: Bool = true"))
    #expect(split.contains("if !showsDividerLine, !isKeyboardFocused, !isHovered, !isDragging"))
  }

  @Test("Reviews content-detail width uses durable app storage")
  func reviewsContentDetailWidthUsesDurableAppStorage() throws {
    let route = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsRouteView.swift"
    )

    #expect(route.contains("DashboardReviewsContentDetailWidthRestoration"))
    #expect(route.contains("@AppStorage(DashboardReviewsContentDetailWidthRestoration.storageKey)"))
    #expect(!route.contains("@SceneStorage(\"dashboard.reviews.content-detail-width\")"))
  }

  @Test("Reviews content mode switch avoids directional move transitions")
  func reviewsContentModeSwitchAvoidsDirectionalMoveTransitions() throws {
    let content = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsRouteView+Content.swift"
    )

    #expect(content.contains("filesModeContentPane(for: item)"))
    #expect(content.contains("reviewsOverviewContentPane"))
    #expect(!content.contains(".move(edge:"))
  }

  @Test("Overview and Files use a peer mode switcher")
  func overviewAndFilesUseAPeerModeSwitcher() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )
    let filesLayout = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane+Layout.swift"
    )
    let accessibility = try source(
      "Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs.swift"
    )

    #expect(detail.contains("struct DashboardReviewDetailModeSwitcher"))
    #expect(detail.contains("DashboardReviewDetailModeSwitcher("))
    #expect(filesLayout.contains("DashboardReviewDetailModeSwitcher("))
    #expect(!filesLayout.contains("Button(action: onBack)"))
    #expect(accessibility.contains("dashboardReviewsModeSwitcher"))
    #expect(accessibility.contains("dashboardReviewsOverviewModeButton"))
    #expect(accessibility.contains("dashboardReviewsFilesModeButton"))
  }

  @Test(
    "Default overview keeps primary sections visible and moves secondary details behind disclosure"
  )
  func defaultOverviewKeepsPrimarySectionsVisibleAndMovesSecondaryDetailsBehindDisclosure()
    throws
  {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )

    #expect(detail.contains("DashboardReviewDetailSection(title: \"Description\")"))
    #expect(detail.contains("DashboardReviewDetailSection(title: \"Activity\")"))
    #expect(detail.contains("DashboardReviewDetailSection(title: \"Labels\")"))
    #expect(detail.contains("DisclosureGroup(isExpanded: $showsSecondaryDetails)"))
    #expect(detail.contains("secondaryDetailsBlock(title: \"Checks\")"))
    #expect(detail.contains("secondaryDetailsBlock(title: \"Reviews\")"))
    #expect(detail.contains("secondaryDetailsBlock(title: \"Comment\")"))
    #expect(!detail.contains("DashboardReviewDetailSection(title: \"Files\")"))
    #expect(!detail.contains("DashboardReviewDetailSection(title: \"Checks\")"))
    #expect(!detail.contains("DashboardReviewDetailSection(title: \"Reviews\")"))
    #expect(!detail.contains("DashboardReviewDetailSection(title: \"Comment\")"))
    #expect(!support.contains("case comment"))
  }

  @Test("Review detail section headers are muted and place dividers below the title")
  func reviewDetailSectionHeadersAreMutedAndPlaceDividersBelowTheTitle() throws {
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )

    #expect(support.contains("Text(title)"))
    #expect(support.contains(".foregroundStyle(HarnessMonitorTheme.secondaryInk)"))
    #expect(support.contains(".accessibilityAddTraits(.isHeader)"))
    #expect(support.contains(".accessibilityAddTraits(.isHeader)\n        Divider().opacity(0.40)"))
    #expect(support.contains("Divider().opacity(0.40)\n      }\n      content()"))
    #expect(!support.contains(".overlay(alignment: .top) {\n      Divider().opacity(0.40)\n    }"))
  }

  @Test("Default overview keeps actionable Files Checks and Reviews signals")
  func defaultOverviewKeepsActionableSummarySignals() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )
    // The signal strip view was extracted into its own file from the detail
    // support companion.
    let signalStrip = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewOverviewSignalStrip.swift"
    )

    #expect(detail.contains("DashboardReviewOverviewSignalStrip("))
    #expect(signalStrip.contains("struct DashboardReviewOverviewSignalStrip"))
    #expect(signalStrip.contains("detailMode = .files"))
    #expect(
      signalStrip.contains("jumpTarget = DashboardReviewDetailSectionID.moreDetails.rawValue"))
    #expect(support.contains("case moreDetails"))
  }

  @Test("Files availability explains the disabled settings state")
  func filesAvailabilityExplainsDisabledSettingsState() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )

    #expect(support.contains("enum DashboardReviewsFilesModeAvailability"))
    #expect(support.contains("case disabledInPreferences"))
    #expect(support.contains("\"Files are turned off in Reviews settings\""))
    #expect(support.contains("\"Enable in Reviews settings\""))
    #expect(support.contains("var systemImage: String"))
    #expect(support.contains("case .available:"))
    #expect(support.contains("\"doc.on.doc\""))
    #expect(support.contains("\"doc\""))
    #expect(!support.contains("\"doc.slash\""))
    #expect(detail.contains("filesAvailability: filesAvailability"))
  }

  @Test("Detail surface and header share the same window background")
  func detailSurfaceAndHeaderShareWindowBackground() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )

    #expect(detail.contains("DashboardReviewDetailHeader("))
    #expect(detail.contains("item: item,"))
    #expect(detail.contains(".background(Color(nsColor: .windowBackgroundColor))"))
    #expect(!detail.contains("DashboardReviewDetailPinnedHeaderBackground()"))
    #expect(!detail.contains(".frame(height: 18)"))
    #expect(!detail.contains("@Environment(\\.accessibilityReduceTransparency)"))
    #expect(!detail.contains("NSVisualEffectView"))
    #expect(support.contains("DashboardReviewAttentionSummary(item: item)"))
    #expect(!detail.contains("DashboardReviewProvenanceMiniBar"))
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
    let fileCardActions = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFileCard+Actions.swift"
    )

    #expect(!description.contains("Task-list checkboxes update the pull request description."))
    #expect(markdown.contains(".controlSize(.regular)"))
    #expect(markdown.contains("Toggle pull request task-list item"))
    #expect(header.contains("visible of"))
    #expect(header.contains("\"Hide generated files\""))
    #expect(header.contains("\"Hide whitespace-only\""))
    #expect(header.contains("Text(\"Layout\")"))
    #expect(header.contains(".pickerStyle(.segmented)"))
    #expect(header.contains("Text(viewModeLabel(for: mode)).tag(mode)"))
    #expect(fileCard.contains("private var viewedButton"))
    #expect(fileCard.contains("\"Viewed\""))
    #expect(fileCard.contains("viewerCanMarkViewed"))
    #expect(fileCardActions.contains("Label(\"More\", systemImage: \"ellipsis.circle\")"))
    #expect(fileCard.contains("harnessFilterChipButtonStyle(isSelected: isViewed)"))
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

  @Test("Review detail avoids duplicate ForEach ids and empty SF Symbols")
  func reviewDetailAvoidsInvalidSwiftUIConfiguration() throws {
    let reviews = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsReviewLabelLists.swift"
    )
    let reviewModels = try source(
      "Sources/HarnessMonitorKit/Models/HarnessMonitorReviewActionModels.swift"
    )
    let fileCard = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFileCard.swift"
    )
    let header = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesHeader.swift"
    )

    #expect(reviews.contains("positionedReviews = reviews.enumerated().map"))
    #expect(reviews.contains("ForEach(positionedReviews) { positionedReview in"))
    #expect(!reviews.contains("ForEach(reviews) { review in"))
    #expect(reviewModels.contains("public struct PullRequestReview: Codable, Equatable, Sendable"))
    #expect(
      !reviewModels.contains(
        "public struct PullRequestReview: Codable, Equatable, Identifiable, Sendable"
      )
    )
    #expect(header.contains("viewModeLabel(for: mode)"))
    #expect(header.contains(".pickerStyle(.segmented)"))
    #expect(!fileCard.contains("systemImage: viewMode == .unified ? \"checkmark\" : \"\""))
    #expect(!fileCard.contains("systemImage: viewMode == .split ? \"checkmark\" : \"\""))
  }

  func source(_ appLocalPath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = appRoot.appendingPathComponent(appLocalPath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }

  func conversationFeedSource() throws -> String {
    let directory = "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
    return try [
      "DashboardReviewConversationFeed.swift",
      "DashboardReviewConversationFeed+Timeline.swift",
      "DashboardReviewConversationTimelineSupport.swift",
      "DashboardReviewConversationFullContent.swift",
      "DashboardReviewConversationCollapsedGapDivider.swift",
    ]
    .map { try source(directory + $0) }
    .joined(separator: "\n")
  }
}
