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

    #expect(detail.contains("DashboardReviewOverviewSignalStrip("))
    #expect(support.contains("struct DashboardReviewOverviewSignalStrip"))
    #expect(support.contains("detailMode = .files"))
    #expect(support.contains("jumpTarget = DashboardReviewDetailSectionID.moreDetails.rawValue"))
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

  @Test("Header actions stay in one horizontal command row")
  func headerActionsStayInOneHorizontalCommandRow() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains("ScrollView(.horizontal)"))
    #expect(actionBar.contains("HStack(spacing: HarnessMonitorTheme.itemSpacing)"))
    #expect(
      actionBar.contains("HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing)")
    )
    #expect(!actionBar.contains("HarnessMonitorWrapLayout("))
    #expect(actionBar.contains("Label(\"More\", systemImage: \"ellipsis.circle\")"))
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

  @Test("Header command row tucks secondary review actions behind a More menu")
  func headerCommandRowTucksSecondaryActionsBehindMoreMenu() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains("Label(\"More\", systemImage: \"ellipsis.circle\")"))
    #expect(
      actionBar.contains("HarnessMonitorAccessibility.dashboardReviewsMoreButton")
    )
    #expect(actionBar.contains("Label(pinActionTitle, systemImage: pinActionSystemImage)"))
    #expect(actionBar.contains("Label(\"Copy approval links\", systemImage: \"doc.on.doc\")"))
    #expect(actionBar.contains("Label(\"Open pull request\", systemImage: \"safari\")"))

    let pinIndex = actionBar.range(
      of: "Label(pinActionTitle, systemImage: pinActionSystemImage)"
    )?.lowerBound
    let openIndex = actionBar.range(
      of: "Label(\"Open pull request\", systemImage: \"safari\")"
    )?.lowerBound
    let copyIndex = actionBar.range(
      of: "Label(\"Copy approval links\", systemImage: \"doc.on.doc\")"
    )?.lowerBound

    if let pinIndex, let openIndex {
      #expect(pinIndex < openIndex)
    }
    if let pinIndex, let copyIndex {
      #expect(pinIndex < copyIndex)
    }
  }

  @Test("Header command row pins the More menu to the trailing edge")
  func headerCommandRowPinsTheMoreMenuToTheTrailingEdge() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains("private var scrollingButtons: some View"))
    #expect(actionBar.contains("scrollingButtons\n        moreActionsMenu"))
    #expect(actionBar.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
  }

  @Test("Auto button appears first with primary prominence; Approve and Merge are secondary")
  func autoButtonIsFirstAndPrimaryApproveAndMergeAreSecondary() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )
    let autoIndex = actionBar.range(of: "action: onAuto")?.lowerBound
    let approveIndex = actionBar.range(of: "action: onApprove")?.lowerBound
    if let autoIndex, let approveIndex {
      #expect(autoIndex < approveIndex, "Auto button must precede Approve in button layout")
    }
    #expect(actionBar.contains("prominence: .primary"))
    #expect(!actionBar.contains("prominence: .utility"))
    let attentionActions = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsAttentionActions.swift"
    )
    #expect(!attentionActions.contains("dashboardReviewApproveProminence"))
    #expect(!attentionActions.contains("dashboardReviewMergeProminence"))
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

  @Test("Approve button reads as an affirmation only when the viewer has approved")
  func approveButtonReadsAsAffirmationOnlyWhenViewerHasApproved() throws {
    let actionBar = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewActionBar.swift"
    )

    #expect(actionBar.contains("\"Approved by you\""))
    #expect(actionBar.contains("\"checkmark.seal.fill\""))
    #expect(actionBar.contains("isShowingApprovedAffirmation"))
    #expect(actionBar.contains("item.reviewStatus == .approved"))
    #expect(actionBar.contains("let viewerLogin: String?"))
    #expect(actionBar.contains("$0.author == login && $0.state == .approved"))
  }

  @Test("Status summary explains policy blocks instead of piling up ambiguous chips")
  func statusSummaryExplainsPolicyBlocks() throws {
    let visuals = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsVisualComponents.swift"
    )
    let enumPresentation = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsEnumPresentation.swift"
    )
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )

    #expect(visuals.contains("Text(item.statusSummarySentence)"))
    #expect(visuals.contains("DashboardReviewAttentionSummary"))
    #expect(visuals.contains("Text(item.attentionTitle)"))
    #expect(visuals.contains("Text(item.attentionSentence)"))
    #expect(visuals.contains("summaryChipsRow"))
    #expect(visuals.contains("ViewThatFits(in: .horizontal)"))
    #expect(visuals.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    #expect(visuals.contains("supplementaryReviewStatusLabel"))
    #expect(visuals.contains("if case .changesRequested = primaryAttentionReason"))
    #expect(visuals.contains("if case .policyBlocked = primaryAttentionReason"))
    #expect(visuals.contains("\"Policy blocked\""))
    #expect(visuals.contains("case .mergeConflicts:"))
    #expect(visuals.contains("HarnessMonitorTheme.danger"))
    #expect(visuals.contains("\"Satisfy the review policy before merging.\""))
    #expect(support.contains("if item.requiresAttention {"))
    #expect(support.contains("DashboardReviewAttentionSummary(item: item)"))
    #expect(support.contains("} else {"))
    #expect(support.contains("DashboardReviewStatusStrip(item: item)"))
    #expect(enumPresentation.contains("case requiresAttention: HarnessMonitorTheme.caution"))
    #expect(!visuals.contains("Text(\"Files\")"))
    #expect(!visuals.contains("\"Policy wait\""))
  }

  @Test("Change pill uses colored plus-minus counts with an accessible line-change summary")
  func changePillUsesColoredPlusMinusCountsWithAccessibleLineChangeSummary() throws {
    let visuals = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsVisualComponents.swift"
    )
    #expect(visuals.contains("Line changes: \\(additions)"))
    #expect(visuals.contains("Text(verbatim: \"+\\(additions)\")"))
    #expect(visuals.contains("Text(verbatim: \"-\\(deletions)\")"))
    #expect(visuals.contains("HarnessMonitorTheme.success"))
    #expect(visuals.contains("HarnessMonitorTheme.danger"))
    #expect(
      visuals.contains(
        "HStack(spacing: style == .compact ? HarnessMonitorTheme.spacingXS : HarnessMonitorTheme.spacingSM)"
      )
    )
    #expect(visuals.contains(".fixedSize(horizontal: true, vertical: false)"))
    #expect(!visuals.contains("Image(systemName: \"arrow.up\")"))
    #expect(!visuals.contains("Image(systemName: \"arrow.down\")"))
    #expect(!visuals.contains("Text(\"Files\")"))
  }

  @Test("Header metadata row links repository and author as muted inline segments")
  func headerMetadataRowLinksRepositoryAndAuthorAsMutedInlineSegments() throws {
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )

    #expect(support.contains("DashboardReviewMetadataLink("))
    #expect(support.contains("title: \"\\(item.repository)#\\(item.number)\""))
    #expect(support.contains("title: \"@\\(item.authorLogin)\""))
    #expect(support.contains("struct DashboardReviewMetadataSeparator: View"))
    #expect(support.contains("DashboardReviewMetadataSeparator()"))
    #expect(support.contains(".layoutPriority(1)"))
    #expect(support.contains("struct DashboardReviewMetadataLinkButtonStyle: ButtonStyle"))
    #expect(support.contains(".scaledFont(.callout)"))
    #expect(support.contains(".onHover { hovering in"))
    #expect(support.contains("HarnessMonitorTheme.tertiaryInk.opacity(0.86)"))
    #expect(support.contains("? HarnessMonitorTheme.tertiaryInk"))
    #expect(!support.contains("HarnessMonitorTheme.secondaryInk : HarnessMonitorTheme.tertiaryInk"))
    #expect(!support.contains(".animation(.easeOut(duration: 0.12), value: isHovering)"))
    #expect(!support.contains(".animation(.easeOut(duration: 0.12), value: configuration.isPressed)"))
    #expect(!support.contains("DashboardReviewInlineChangeStats("))
    #expect(!support.contains(".underline()"))
    #expect(!support.contains("Text(\" · @\")"))
    #expect(!support.contains("Text(\"\\(item.repository)\")"))
    #expect(!support.contains("Text(verbatim: \"#\\(item.number)\")"))
    #expect(!support.contains("Text(item.authorLogin)"))
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
}
