import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension DashboardReviewsDetailUXContractTests {
  @Test("Large review detail collections render in bounded batches")
  func largeReviewDetailCollectionsRenderInBoundedBatches() throws {
    let checks = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewCheckList.swift"
    )
    let checksPresentation = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewCheckListPresentation.swift"
    )
    let conversation = try conversationFeedSource()
    let conversationFooter = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewConversationStatusBar.swift"
    )

    #expect(checks.contains("private static let checkBatchSize = 20"))
    #expect(checks.contains("visibleNonProblemCheckLimit"))
    #expect(checksPresentation.contains("nonProblemChecks.prefix(visibleNonProblemCheckLimit)"))
    #expect(checks.contains("let nextBatchSize = min(Self.checkBatchSize"))
    #expect(checks.contains("Show \\(nextBatchSize) more checks"))

    #expect(conversation.contains("private static let timelineRowBatchSize = 16"))
    #expect(conversation.contains("private static let oldestTimelineAnchorCount = 1"))
    #expect(conversation.contains("DashboardReviewConversationVisibilityWindow("))
    #expect(conversation.contains("rowSource.rows.prefix(window.leadingVisibleRowsCount)"))
    #expect(conversation.contains("rowSource.rows.suffix(window.trailingVisibleRowsCount)"))
    #expect(conversation.contains("DashboardReviewConversationSegmentedTimelineRows("))
    #expect(conversation.contains("DashboardReviewConversationCollapsedGapRailOverlay("))
    #expect(conversation.contains("startRowID: lastHeadRowID"))
    #expect(conversation.contains("endRowID: firstTailRowID"))
    #expect(conversation.contains("DashboardReviewConversationCollapsedGapDivider("))
    #expect(conversation.contains("gapAction: .show(window.nextExpansionCount)"))
    #expect(conversation.contains("gapAction: .hide(collapsedWindow.hiddenMiddleRowCount)"))
    #expect(conversation.contains("let expandedTimelineHeadRows = rowSource.rows.prefix("))
    #expect(conversation.contains("let expandedTimelineTailRows = rowSource.rows.suffix("))
    #expect(conversation.contains("visibleTimelineRowLimit = Self.timelineRowBatchSize"))
    #expect(conversation.contains("Text(title)"))
    #expect(conversation.contains("CollapsedGapDividerButtonStyle("))
    #expect(conversation.contains("CollapsedGapDividerLabel("))
    #expect(conversation.contains("pointerStyle(.link)"))
    #expect(conversation.contains("Color.clear"))
    #expect(conversation.contains(".frame(width: SessionTimelineLayout.timeColumnWidth)"))
    #expect(conversation.contains("Path { path in"))
    #expect(conversation.contains(".padding(.vertical, HarnessMonitorTheme.spacingXS)"))
    #expect(conversation.contains("dash: [1, 5]"))
    #expect(conversation.contains("dash: [1, 4]"))
    #expect(
      conversation.contains(
        "@Entry fileprivate var collapsedGapDividerInteractionState:"
      )
    )
    #expect(conversation.contains(".foregroundStyle(interactionState.textColor)"))
    #expect(conversation.contains("HarnessMonitorTheme.accent"))
    #expect(conversation.contains("HarnessMonitorTheme.controlBorder.opacity(0.42)"))
    #expect(conversation.contains("HarnessMonitorTheme.warmAccent"))
    #expect(conversationFooter.contains("visibleRowsCount < totalRowsCount"))
  }

  @Test("Review conversation gap restores its scroll anchor when toggled")
  func reviewConversationGapRestoresItsScrollAnchorWhenToggled() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )
    let conversation = try conversationFeedSource()

    #expect(
      detail.contains(
        "DashboardReviewConversationFeed(\n                item: item,\n"
          + "                store: store,\n                viewerLogin: viewerLogin,\n"
          + "                actionHandler: store.supervisorDecisionActionHandler(),\n"
          + "                onGapScrollCompensation: { deltaY in"
      )
    )
    #expect(detail.contains("DashboardReviewGapScrollCompensationApplicator("))
    #expect(
      detail.contains(
        "gapScrollCompensationRequest = DashboardReviewGapScrollCompensationRequest("
      )
    )
    #expect(detail.contains("SettingsScrollRestoreApplicator.currentOffset(in: scrollView)"))

    #expect(conversation.contains("pendingGapScrollCompensation = .init(targetMinY: currentMinY)"))
    #expect(conversation.contains("let deltaY = minY - pendingGapScrollCompensation.targetMinY"))
    #expect(conversation.contains("pendingGapScrollCompensation.lastEmittedDeltaY = deltaY"))
    #expect(conversation.contains("onGapScrollCompensation?(deltaY)"))
    #expect(
      conversation.contains(
        "proxy.frame(in: .named(DashboardReviewDetailScrollCoordinateSpace.name)).minY"))
  }

  @Test("Activity timeline opens rich rows through a lazy local markdown sheet")
  func activityTimelineOpensRichRowsThroughALazyLocalMarkdownSheet() throws {
    let conversation = try conversationFeedSource()
    let timeline = try sessionTimelineCardsSource()

    #expect(conversation.contains("@State private var presentedFullContent"))
    #expect(conversation.contains("@State private var fullContentCacheRevision"))
    #expect(conversation.contains("private var fullContentCache"))
    #expect(conversation.contains("if let cached = fullContentCache[node.identity]"))
    #expect(conversation.contains("if fullContentCacheRevision != revision"))
    #expect(conversation.contains(".sheet(item: $presentedFullContent)"))
    #expect(
      conversation.contains("HarnessMonitorMarkdownText(content.markdown, textSelection: .enabled)")
    )
    #expect(conversation.contains(".padding(.bottom, HarnessMonitorTheme.spacingLG)"))
    #expect(conversation.contains("DashboardReviewConversationFullContentSheetMetricsReader()"))
    #expect(!conversation.contains("@State private var sheetMetrics"))
    #expect(!conversation.contains("@Binding var metrics"))
    #expect(conversation.contains("sheetWindow?.sheetParent ?? sheetWindow"))
    #expect(
      conversation.contains(
        "private var appliedSizing: AppliedSizing?"
      )
    )
    #expect(conversation.contains("private var refreshScheduled = false"))
    #expect(!conversation.contains("sheetWindow.contentMinSize"))
    #expect(
      conversation.contains("let maximumContentSize = metrics.maximumContentSize(chromeSize: chromeSize)")
    )
    #expect(conversation.contains("sheetWindow.contentMaxSize = maximumContentSize"))
    #expect(conversation.contains("sheetWindow.contentView?.layoutSubtreeIfNeeded()"))
    #expect(conversation.contains("let preferredSize = preferredContentSize(in: sheetWindow)"))
    #expect(
      conversation.contains(
        "let cappedSize = metrics.cappedContentSize(for: preferredSize, chromeSize: chromeSize)"
      )
    )
    #expect(conversation.contains("let sizing = AppliedSizing("))
    #expect(conversation.contains("guard appliedSizing != sizing else { return }"))
    #expect(conversation.contains("sheetWindow.setContentSize(cappedSize)"))
    #expect(conversation.contains("sheetWindow.frameRect(forContentRect: contentRect)"))
    #expect(conversation.contains("parentFrame.width - (toolbarHeight * 2)"))
    #expect(conversation.contains("parentFrame.height - (toolbarHeight * 2)"))
    #expect(timeline.contains("let onOpenFullContent: ((SessionTimelineNode) -> Void)?"))
    #expect(timeline.contains("let fullContentRevision: UInt64?"))
    #expect(
      timeline.contains(
        "node.canOpenFullContent && onOpenFullContent != nil && node.actions.isEmpty"))
    #expect(timeline.contains("var cardArea: some View"))
    #expect(timeline.contains("var cardContainer: some View"))
    #expect(timeline.contains(".padding(cardInsets)"))
    #expect(timeline.contains(".background(SessionTimelineCardBackground(tint: cardTint))"))
    #expect(timeline.contains("SessionTimelineImmediateCardButtonStyle"))
    #expect(timeline.contains(".onHover { hovering in"))
    #expect(timeline.contains("transaction.animation = nil"))
    #expect(timeline.contains("onOpenFullContent?(node)"))
    #expect(timeline.contains(".pointerStyle(.link)"))
  }

  @Test("Activity full content sheet metrics keep toolbar-sized window margins")
  func activityFullContentSheetMetricsKeepToolbarSizedWindowMargins() {
    let metrics = DashboardReviewConversationFullContentSheetMetrics.resolved(
      parentFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900),
      parentContentLayoutRect: CGRect(x: 0, y: 0, width: 1_200, height: 840)
    )

    #expect(metrics.toolbarHeight == 60)
    #expect(metrics.maxWidth == 1_080)
    #expect(metrics.maxHeight == 780)
    #expect(metrics.minimumWidth == 360)
    #expect(metrics.idealWidth == 760)
    #expect(metrics.minimumHeight == 420)
    #expect(metrics.idealHeight == 520)
    #expect(metrics.minimumContentSize == CGSize(width: 360, height: 420))
    #expect(
      metrics.maximumContentSize(chromeSize: CGSize(width: 8, height: 28))
        == CGSize(width: 1_072, height: 752)
    )
    #expect(
      metrics.cappedContentSize(
        for: CGSize(width: 600, height: 500),
        chromeSize: CGSize(width: 8, height: 28)
      ) == CGSize(width: 600, height: 500)
    )
    #expect(
      metrics.cappedContentSize(
        for: CGSize(width: 1_600, height: 900),
        chromeSize: CGSize(width: 8, height: 28)
      ) == CGSize(width: 1_072, height: 752)
    )
  }

  @Test("Activity inline conversations render through a dedicated GitHub style card path")
  func activityInlineConversationsRenderThroughADedicatedGitHubStyleCardPath() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )
    let conversation = try conversationFeedSource()
    let inlineConversation = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewActivityInlineConversation.swift"
    )
    let inlineStore = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesInlineCommentStore.swift"
    )
    let inlineCard = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewInlineThreadCard.swift"
    )
    let builder = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Timeline/ReviewPullRequestTimelineNodeBuilder.swift"
    )
    let timeline = try sessionTimelineCardsSource()

    #expect(detail.contains("viewerLogin: viewerLogin"))
    #expect(conversation.contains("@State private var inlineConversationCollapseRevision"))
    #expect(conversation.contains("@State private var inlineConversationCollapsedThreadIDs"))
    #expect(conversation.contains("ReviewActivityInlineConversationRendererContext("))
    #expect(
      conversation.contains("onSetCollapsed: setInlineConversationCollapsed(threadID:collapsed:)"))
    #expect(conversation.contains("postReviewThreadReply("))
    #expect(inlineConversation.contains("struct DashboardReviewActivityInlineConversation"))
    #expect(inlineConversation.contains("struct DashboardReviewActivityQuotedDiffContext"))
    #expect(inlineConversation.contains("enum DashboardReviewActivityInlineConversationBuilder"))
    #expect(inlineCard.contains("let quotedDiffContext: DashboardReviewActivityQuotedDiffContext?"))
    #expect(inlineCard.contains("let truncationNotice: String?"))
    #expect(inlineCard.contains("quotedDiffContextSection"))
    #expect(builder.contains("let visibleReviewThreadSignatures"))
    #expect(builder.contains("inlineConversationSignature(for: group)"))
    #expect(builder.contains("node.reviewInlineConversation = conversation"))
    #expect(builder.contains("DashboardReviewActivityInlineConversationBuilder.build("))
    #expect(
      timeline.contains(
        "let reviewInlineConversationContext: ReviewActivityInlineConversationRendererContext?"
      ))
    #expect(timeline.contains("var hasCustomInlineConversation: Bool"))
    #expect(timeline.contains("DashboardReviewInlineThreadCard("))
    #expect(timeline.contains("quotedDiffContext: conversation.quotedDiffContext"))
    #expect(timeline.contains("reviewInlineConversationContext.collapsedThreadIDs"))
    #expect(timeline.contains("Some comments are still only available on GitHub."))
    #expect(inlineStore.contains("func postReviewThreadReply("))
  }

  @Test("Comment composer moves behind the secondary details disclosure")
  func commentComposerMovesBehindTheSecondaryDetailsDisclosure() throws {
    let detail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailView.swift"
    )
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )
    let composer = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewCommentComposer.swift"
    )

    #expect(detail.contains("showsComposer: false"))
    #expect(detail.contains("DisclosureGroup(isExpanded: $showsSecondaryDetails)"))
    #expect(detail.contains("secondaryDetailsBlock(title: \"Comment\")"))
    #expect(detail.contains("commentComposerSection(viewModel: viewModel)"))
    #expect(!detail.contains("DashboardReviewDetailSection(title: \"Comment\")"))
    #expect(!detail.contains(".safeAreaInset(edge: .bottom, spacing: 12)"))
    #expect(support.contains("DashboardReviewDetailModeSwitcher"))
    #expect(!support.contains("case comment"))
    #expect(!support.contains("case .comment: \"Comment\""))
    #expect(!composer.contains("@State private var isCollapsed"))
    #expect(!composer.contains("collapsedBar"))
    #expect(!composer.contains("Collapse comment composer"))
    #expect(!composer.contains(".padding(.horizontal, 16)"))
  }

  @Test("Pull request numbers render verbatim instead of localized grouped values")
  func pullRequestNumbersRenderVerbatimInsteadOfLocalizedGroupedValues() throws {
    let detailHeader = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewDetailSupport.swift"
    )
    let filesOverview = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane+Layout.swift"
    )
    let filesDetail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesModeDetailPane.swift"
    )
    let mobileReviews = try source(
      "Sources/HarnessMonitorMobile/MobileReviewsView.swift"
    )
    let mobileReviewCommandForm = try source(
      "Sources/HarnessMonitorMobile/MobileReviewsView+CommandForm.swift"
    )
    let mobileComposer = try source(
      "Sources/HarnessMonitorMobile/MobileCommandComposerView.swift"
    )
    let watchComposer = try source(
      "Sources/HarnessMonitorWatch/WatchCommandComposerView.swift"
    )

    #expect(detailHeader.contains("title: \"\\(item.repository)#\\(item.number)\""))
    #expect(detailHeader.contains("Text(verbatim: title)"))
    #expect(!detailHeader.contains("Text(verbatim: \"#\\(item.number)\")"))
    #expect(!detailHeader.contains("Text(\"#\\(item.number)\")"))

    #expect(filesOverview.contains("DashboardReviewInlineTitle("))
    #expect(filesOverview.contains("Text(verbatim: \"#\\(item.number)\")"))
    #expect(!filesOverview.contains("Text(verbatim: \"\\(item.title) #\\(item.number)\")"))

    #expect(filesDetail.contains("Text(file.path)"))
    #expect(!filesDetail.contains("Text(verbatim: \"\\(item.repository) #\\(item.number)\")"))

    #expect(mobileReviews.contains("Text(verbatim: \"#\\(review.number)\")"))
    #expect(!mobileReviews.contains("Text(\"#\\(review.number)\")"))
    #expect(
      mobileReviewCommandForm.contains(
        "Text(verbatim: \"#\\(action.review.number) \\(action.review.title)\")"
      )
    )
    #expect(
      !mobileReviewCommandForm.contains(
        "Text(\"#\\(action.review.number) \\(action.review.title)\")"
      )
    )

    #expect(
      mobileComposer.contains(
        "Text(verbatim: \"#\\(review.number) \\(review.title)\").tag(review.id)"
      )
    )
    #expect(
      !mobileComposer.contains(
        "Text(\"#\\(review.number) \\(review.title)\").tag(review.id)"
      )
    )

    #expect(watchComposer.contains("Text(verbatim: \"#\\(review.number)\").tag(review.id)"))
    #expect(!watchComposer.contains("Text(\"#\\(review.number)\").tag(review.id)"))
  }

  @Test("Mobile command composers preserve selected mirror payloads")
  func mobileCommandComposersPreserveSelectedMirrorPayloads() throws {
    let sharedDraftHelpers = try source(
      "Sources/HarnessMonitorMirrorStore/CommandFormModel+Draft.swift"
    )

    #expect(sharedDraftHelpers.contains("var selectedReviewDraft: MobileCommandDraft?"))
    #expect(sharedDraftHelpers.contains("review.commandDraft("))
    #expect(sharedDraftHelpers.contains("var selectedTaskDraft: MobileCommandDraft?"))
    #expect(sharedDraftHelpers.contains("task.commandDraft("))
  }

  /// The timeline card view was split across companions for the file-length
  /// cap (card content, components, layout). Union-read the family so the
  /// pinned card-rendering literals resolve wherever they landed.
  func sessionTimelineCardsSource() throws -> String {
    let directory = "Sources/HarnessMonitorUIPreviewable/Views/Timeline/"
    return try [
      "SessionTimelineCards.swift",
      "SessionTimelineCards+CardContent.swift",
      "SessionTimelineCards+Components.swift",
      "SessionTimelineCardLayout.swift",
    ]
    .map { try source(directory + $0) }
    .joined(separator: "\n")
  }
}
