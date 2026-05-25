import Foundation
import Testing

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
    let files = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesSection.swift"
    )
    let conversation = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewConversationFeed.swift"
    )
    let conversationFooter = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewConversationStatusBar.swift"
    )

    #expect(checks.contains("private static let checkBatchSize = 20"))
    #expect(checks.contains("visibleNonProblemCheckLimit"))
    #expect(checksPresentation.contains("nonProblemChecks.prefix(visibleNonProblemCheckLimit)"))
    #expect(checks.contains("let nextBatchSize = min(Self.checkBatchSize"))
    #expect(checks.contains("Show \\(nextBatchSize) more checks"))

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

  @Test("Comment composer scrolls below conversation as its own detail block")
  func commentComposerScrollsBelowConversationAsItsOwnDetailBlock() throws {
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
    #expect(detail.contains("DashboardReviewDetailSection(title: \"Comment\")"))
    #expect(detail.contains("commentComposerSection(viewModel: viewModel)"))
    #expect(detail.contains(".id(DashboardReviewDetailSectionID.comment.rawValue)"))
    #expect(!detail.contains(".safeAreaInset(edge: .bottom, spacing: 12)"))
    #expect(support.contains("case comment"))
    #expect(support.contains("case .comment: \"Comment\""))
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

    #expect(detailHeader.contains("Text(verbatim: \"#\\(item.number)\")"))
    #expect(!detailHeader.contains("Text(\"#\\(item.number)\")"))

    #expect(filesOverview.contains("dashboardReviewDisplayedTitle("))
    #expect(filesOverview.contains("Text(verbatim: \"#\\(item.number)\")"))
    #expect(!filesOverview.contains("Text(verbatim: \"\\(item.title) #\\(item.number)\")"))

    #expect(filesDetail.contains("Text(verbatim: \"\\(item.repository) #\\(item.number)\")"))
    #expect(!filesDetail.contains("Text(\"\\(item.repository) #\\(item.number)\")"))

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
    let mobileComposerHelpers = try source(
      "Sources/HarnessMonitorMobile/MobileCommandComposerViewHelpers.swift"
    )
    let watchComposerHelpers = try source(
      "Sources/HarnessMonitorWatch/WatchCommandComposerViewHelpers.swift"
    )

    for composer in [mobileComposerHelpers, watchComposerHelpers] {
      #expect(composer.contains("var selectedReviewDraft: MobileCommandDraft?"))
      #expect(composer.contains("review.commandDraft("))
      #expect(composer.contains("var selectedTaskDraft: MobileCommandDraft?"))
      #expect(composer.contains("task.commandDraft("))
    }
  }
}
