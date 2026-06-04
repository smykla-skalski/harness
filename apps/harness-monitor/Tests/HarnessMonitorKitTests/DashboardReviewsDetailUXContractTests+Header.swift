import Foundation
import Testing

extension DashboardReviewsDetailUXContractTests {
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
    #expect(enumPresentation.contains("case requiresAttention: HarnessMonitorTheme.danger"))
    #expect(!visuals.contains("Text(\"Files\")"))
    #expect(!visuals.contains("\"Policy wait\""))
  }

  @Test("Change pill uses colored plus-minus counts with an accessible line-change summary")
  func changePillUsesColoredPlusMinusCountsWithAccessibleLineChangeSummary() throws {
    let visuals = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsVisualComponents+Pills.swift"
    )
    #expect(visuals.contains("Line changes: \\(additions)"))
    #expect(visuals.contains("Text(verbatim: \"+\\(additions)\")"))
    #expect(visuals.contains("Text(verbatim: \"-\\(deletions)\")"))
    #expect(visuals.contains("HarnessMonitorTheme.success"))
    #expect(visuals.contains("HarnessMonitorTheme.danger"))
    #expect(
      visuals.contains(
        "spacing: style == .compact ? HarnessMonitorTheme.spacingXS : HarnessMonitorTheme.spacingSM"
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
    #expect(
      !support.contains(".animation(.easeOut(duration: 0.12), value: configuration.isPressed)"))
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
}
