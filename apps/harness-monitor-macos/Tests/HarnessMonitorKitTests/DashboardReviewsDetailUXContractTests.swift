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

    #expect(detail.contains("DashboardReviewDetailHeader("))
    #expect(detail.contains("item: item,"))
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

  @Test("Header command row hints horizontal overflow with a trailing fade mask")
  func headerCommandRowHintsHorizontalOverflowWithFadeMask() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains(".mask("))
    #expect(actionBar.contains("LinearGradient("))
    #expect(actionBar.contains("startPoint: .leading"))
    #expect(actionBar.contains("endPoint: .trailing"))
  }

  @Test("Bot rebase and Fix CI buttons explain their conditional appearance")
  func botRebaseAndFixCIButtonsExplainConditionalAppearance() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains("Available because @\\(item.authorLogin) is a known bot"))
    #expect(actionBar.contains("\"Available because required checks are failing\""))
    #expect(actionBar.contains("\"Rerun checks\""))
    #expect(!actionBar.contains("\"Rerun Checks\""))
  }

  @Test("Approve button reads as an affirmation once the viewer has approved")
  func approveButtonReadsAsAffirmationOnceViewerHasApproved() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains("\"Approved by you\""))
    #expect(actionBar.contains("\"checkmark.seal.fill\""))
    #expect(actionBar.contains("isShowingApprovedAffirmation"))
    #expect(actionBar.contains("item.reviewStatus == .approved"))
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

  @Test("Change pill exposes Files framing to assistive tech and adds shape glyphs")
  func changePillExposesFilesFramingAndShapeGlyphs() throws {
    let visuals = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsVisualComponents.swift"
    )
    #expect(visuals.contains("Files: \\(additions)"))
    #expect(visuals.contains("Image(systemName: \"arrow.up\")"))
    #expect(visuals.contains("Image(systemName: \"arrow.down\")"))
    #expect(visuals.contains("style == .compact ? \"+\\(additions)\" : \"\\(additions)\""))
    #expect(visuals.contains("style == .compact ? \"-\\(deletions)\" : \"\\(deletions)\""))
    #expect(
      visuals.contains("HStack(spacing: style == .compact ? HarnessMonitorTheme.spacingXS : 0)"))
    #expect(visuals.contains(".fixedSize(horizontal: true, vertical: false)"))
  }

  @Test("Status pill drops icon when attention summary owns it")
  func statusPillDropsIconWhenAttentionSummaryOwnsIt() throws {
    let visuals = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsVisualComponents.swift"
    )
    #expect(visuals.contains("item.requiresAttention ? nil : item.statusSystemImage"))
  }

  @Test("Approved pill is suppressed when attention is required")
  func approvedPillSuppressedWhenAttentionRequired() throws {
    let visuals = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsVisualComponents.swift"
    )
    #expect(visuals.contains("!(item.requiresAttention && item.reviewStatus == .approved)"))
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

    #expect(!description.contains("Task-list checkboxes update the pull request description."))
    #expect(markdown.contains(".controlSize(.regular)"))
    #expect(markdown.contains("Toggle pull request task-list item"))
    #expect(header.contains("visible of"))
    #expect(header.contains("\"Hide generated files\""))
    #expect(header.contains("\"Hide whitespace-only\""))
    #expect(fileCard.contains("Toggle(\n        \"Viewed\""))
    #expect(fileCard.contains("Label(viewMode.label, systemImage: \"rectangle.split.2x1\")"))
  }

  @Test("Files section waits for daemon and retries when the daemon comes online")
  func filesSectionWaitsForDaemonAndRetries() throws {
    let files = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesSection.swift"
    )

    #expect(
      files.contains(
        "let isDaemonOnline = store.connectionState == .online "
          + "&& store.apiClient != nil"
      )
    )
    #expect(files.contains("ReviewFilesTaskKey("))
    #expect(files.contains("guard isDaemonOnline else { return }"))
    #expect(files.contains("case waitingForDaemon"))
    #expect(files.contains("\"Waiting for daemon connection\""))
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
    let fileCard = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFileCard.swift"
    )

    #expect(reviews.contains("Array(reviews.enumerated())"))
    #expect(!reviews.contains("ForEach(reviews)"))
    #expect(fileCard.contains("viewModeMenuLabel(for: .unified)"))
    #expect(fileCard.contains("viewModeMenuLabel(for: .split)"))
    #expect(!fileCard.contains("systemImage: viewMode == .unified ? \"checkmark\" : \"\""))
    #expect(!fileCard.contains("systemImage: viewMode == .split ? \"checkmark\" : \"\""))
  }

  @Test("Large review detail collections render in bounded batches")
  func largeReviewDetailCollectionsRenderInBoundedBatches() throws {
    let checks = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewCheckList.swift"
    )
    let files = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesSection.swift"
    )
    let conversation = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewConversationFeed.swift"
    )
    let conversationFooter = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewConversationStatusBar.swift"
    )

    #expect(checks.contains("private static let checkBatchSize = 20"))
    #expect(checks.contains("visibleNonProblemCheckLimit"))
    #expect(checks.contains("Array(nonProblemChecks.prefix(visibleNonProblemCheckLimit))"))
    #expect(checks.contains("Show \\(min(Self.checkBatchSize, hiddenNonProblemCheckCount))"))

    #expect(files.contains("private static let fileBatchSize = 24"))
    #expect(files.contains("viewModel.filteredFiles.prefix(visibleFileLimit)"))
    #expect(files.contains("Show \\(min(Self.fileBatchSize, hiddenCount)) more files"))

    #expect(conversation.contains("private static let timelineRowBatchSize = 16"))
    #expect(conversation.contains("rowSource.rows.prefix(visibleTimelineRowLimit)"))
    #expect(
      conversation.contains(
        "Show \\(min(Self.timelineRowBatchSize, hiddenTimelineRowCount)) more events"
      )
    )
    #expect(conversationFooter.contains("visibleRowsCount < totalRowsCount"))
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
