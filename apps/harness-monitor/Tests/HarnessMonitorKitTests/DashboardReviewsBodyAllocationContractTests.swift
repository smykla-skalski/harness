import Testing

@Suite("Dashboard reviews body allocation contracts")
struct DashboardReviewsBodyAllocationContractTests {
  @Test("body paths avoid transient ForEach arrays")
  func bodyPathsAvoidTransientForEachArrays() throws {
    let files = [
      "DashboardReviewCheckList.swift",
      "DashboardReviewFilesModeContentPane.swift",
      "DashboardReviewsLabelPicker.swift",
      "DashboardReviewsProvenance+Popover.swift",
      "DashboardReviewsReviewLabelLists.swift",
    ]

    for file in files {
      let source = try dashboardReviewsRouteSource(named: file)
      #expect(!source.contains("ForEach(Array("))
    }
  }

  @Test("check list body derives presentation without transient prefix arrays")
  func checkListBodyDerivesPresentationWithoutTransientPrefixArrays() throws {
    let checkListSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewCheckList.swift"
    )
    let presentationSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewCheckListPresentation.swift"
    )
    let reviewCheckSource = try dashboardReviewsAppSource(
      "apps/harness-monitor/Sources/HarnessMonitorKit/Models/HarnessMonitorReviewActionModels.swift"
    )

    #expect(
      checkListSource.contains(
        "@State private var presentationCache = DashboardReviewCheckListPresentationCache()"
      )
    )
    #expect(checkListSource.contains("let presentation = presentationCache.presentation("))
    #expect(presentationSource.contains("final class DashboardReviewCheckListPresentationCache"))
    #expect(presentationSource.contains("struct DashboardReviewCheckListPresentationKey: Hashable"))
    #expect(presentationSource.contains("DashboardReviewCheckListPresentation("))
    #expect(reviewCheckSource.contains("ReviewCheck: Codable, Equatable, Hashable"))
    #expect(!presentationSource.contains("Array(nonProblemChecks.prefix"))
  }

  @Test("dynamic body lists use element identity instead of offsets")
  func dynamicBodyListsUseElementIdentity() throws {
    let labelPickerSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsLabelPicker.swift"
    )
    let provenanceSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsProvenance+Popover.swift"
    )
    let reviewLabelsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsReviewLabelLists.swift"
    )

    #expect(!labelPickerSource.contains("ForEach(groups.indices"))
    #expect(!provenanceSource.contains("ForEach(snapshot.warnings.indices"))
    #expect(!reviewLabelsSource.contains("ForEach(reviews.indices"))
  }

  @Test("timeline body passes visible prefixes without array copies")
  func timelineBodyPassesVisiblePrefixesWithoutArrayCopies() throws {
    let conversationFeedSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewConversationFeed.swift"
    )

    #expect(!conversationFeedSource.contains("Array(rowSource.rows.prefix"))
  }

  @Test("conversation feed caches decoded preferences off body")
  func conversationFeedCachesDecodedPreferencesOffBody() throws {
    let conversationFeedSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewConversationFeed.swift"
    )

    #expect(
      conversationFeedSource.contains(
        "@State private var resolvedPreferences = DashboardReviewsResolvedPreferences("
      )
    )
    #expect(conversationFeedSource.contains("let preferences = resolvedPreferences.preferences"))
    #expect(conversationFeedSource.contains(".onChange(of: storedPreferences, initial: true)"))
    #expect(!conversationFeedSource.contains("private func decodedPreferences()"))
    #expect(
      !conversationFeedSource.contains(
        "DashboardReviewsStorageCodec.decode(\n      DashboardReviewsPreferences.self"
      )
    )
  }

  @Test("list row capped strips pass slices without array copies")
  func listRowCappedStripsPassSlicesWithoutArrayCopies() throws {
    let rowSource = try dashboardReviewsRouteSource(named: "DashboardReviewListRow.swift")
    let labelsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewListRow+Labels.swift"
    )

    #expect(rowSource.contains("ArraySlice<String>"))
    #expect(labelsSource.contains("ArraySlice<String>"))
    #expect(!rowSource.contains("Array(names.prefix"))
    #expect(!labelsSource.contains("Array(labels.prefix"))
  }

  @Test("detail label strip caches repository label lookup")
  func detailLabelStripCachesRepositoryLabelLookup() throws {
    let reviewsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsReviewLabelLists.swift"
    )

    #expect(reviewsSource.contains("private let labelByName"))
    #expect(reviewsSource.contains("uniquingKeysWith: { first, _ in first }"))
    #expect(!reviewsSource.contains("private var labelByName"))
  }

  @Test("provenance popover uses repository prefix slices")
  func provenancePopoverUsesRepositoryPrefixSlices() throws {
    let provenanceSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsProvenance+Popover.swift"
    )

    #expect(provenanceSource.contains("let visibleRepositories = repositories.prefix(5)"))
    #expect(!provenanceSource.contains("Array(repositories.prefix"))
  }

  @Test("files mode content filters visible files with reserved storage")
  func filesModeContentFiltersVisibleFilesWithReservedStorage() throws {
    let filesModeSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeContentPane.swift"
    )
    let presentationSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesPresentation.swift"
    )

    #expect(presentationSource.contains("visibleFiles.reserveCapacity(input.filteredFiles.count)"))
    #expect(!filesModeSource.contains("viewModel.filteredFiles.filter { file in"))
  }

  @Test("files mode prewarm derives paths in one reserved pass")
  func filesModePrewarmDerivesPathsInOneReservedPass() throws {
    let filesModeLoadSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeContentPane+Load.swift"
    )

    #expect(filesModeLoadSource.contains("func prewarmPaths("))
    #expect(
      filesModeLoadSource.contains("visible.reserveCapacity(Self.visiblePreviewPrewarmLimit)")
    )
    #expect(
      filesModeLoadSource.contains(
        "background.reserveCapacity(Self.backgroundPreviewPrewarmLimit)"
      )
    )
    #expect(filesModeLoadSource.contains("if let selected, let file = files.first(where:"))
    #expect(!filesModeLoadSource.contains("let visiblePaths = viewModel.filteredFiles"))
    #expect(!filesModeLoadSource.contains("let remainingPaths = viewModel.filteredFiles"))
    #expect(!filesModeLoadSource.contains("let visibleSet = Set(visiblePaths)"))
    #expect(!filesModeLoadSource.contains("Array(remainingPaths)"))
  }

  @Test("files mode content caches presentation outside the SwiftUI body path")
  func filesModeContentCachesPresentationOutsideBodyPath() throws {
    let filesModeSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeContentPane.swift"
    )
    let presentationSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesPresentation.swift"
    )

    #expect(
      filesModeSource.contains(
        "@State private var presentationCache = DashboardReviewFilesModePresentationCache()"
      )
    )
    #expect(filesModeSource.contains("let presentation = filesPresentation("))
    #expect(filesModeSource.contains("fileList("))
    #expect(filesModeSource.contains("presentation: presentation"))
    #expect(!filesModeSource.contains("DashboardReviewFilesSummary.make("))
    #expect(!filesModeSource.contains("Dictionary(grouping: files)"))
    #expect(presentationSource.contains("final class DashboardReviewFilesModePresentationCache"))
    #expect(presentationSource.contains("struct DashboardReviewFilesModePresentationKey"))
  }

  @Test("files navigator row caches repeated body facts")
  func filesNavigatorRowCachesRepeatedBodyFacts() throws {
    let navigatorRowSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeContentPane+Support.swift"
    )

    #expect(navigatorRowSource.contains("private let fileName: String"))
    #expect(navigatorRowSource.contains("private let unresolvedThreadCount: Int"))
    #expect(navigatorRowSource.contains("private let changeCountLabel: String"))
    #expect(navigatorRowSource.contains("private let accessibilitySummary: String"))
    #expect(!navigatorRowSource.contains("threads.contains(where: { !$0.isResolved })"))
  }

  @Test("list row caches repeated identity labels")
  func listRowCachesRepeatedIdentityLabels() throws {
    let rowSource = try dashboardReviewsRouteSource(named: "DashboardReviewListRow.swift")

    #expect(rowSource.contains("let secondaryText: String?"))
    #expect(rowSource.contains("let inlineIdentityAndAge: String"))
    #expect(rowSource.contains("private let inlineIdentityAndAgeHelp: String"))
    #expect(!rowSource.contains("inlineIdentityAndAgeParts"))
    #expect(!rowSource.contains(".joined(separator: \" · \")"))
  }

  @Test("list row caches attention strip inputs")
  func listRowCachesAttentionStripInputs() throws {
    let rowSource = try dashboardReviewsRouteSource(named: "DashboardReviewListRow.swift")
    let actionsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsAttentionActions.swift"
    )

    #expect(rowSource.contains("private let attentionBadges: DashboardReviewAttentionBadges"))
    #expect(
      rowSource.contains(
        "private let requiredFailedCheckNames: DashboardReviewVisibleRequiredFailedCheckNames?"
      )
    )
    #expect(!rowSource.contains("let attentionBadgeKinds ="))
    #expect(!rowSource.contains("visibleRequiredFailedCheckNames()"))
    #expect(actionsSource.contains("struct DashboardReviewAttentionBadges: Equatable"))
  }

  @Test("list row caches parsed inline title fragments")
  func listRowCachesParsedInlineTitleFragments() throws {
    let rowSource = try dashboardReviewsRouteSource(named: "DashboardReviewListRow.swift")
    let helpersSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewListRowHelpers.swift"
    )

    #expect(rowSource.contains("let displayTitle: String"))
    #expect(rowSource.contains("private let displayTitleInlines: [HarnessMarkdownInline]?"))
    #expect(rowSource.contains("let titleAccessibilityText: String"))
    #expect(
      helpersSource.contains(
        "func dashboardReviewInlineTitleInlines(_ title: String) -> [HarnessMarkdownInline]?"
      )
    )
    #expect(helpersSource.contains("func dashboardReviewInlineTitlePlainText("))
  }

  @Test("files detail menu avoids thread URL arrays in body")
  func filesDetailMenuAvoidsThreadURLArraysInBody() throws {
    let detailSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeDetailPane.swift"
    )

    #expect(detailSource.contains("let fileThreads = threadIndex.threads(forPath: file.path)"))
    #expect(detailSource.contains("private func copyThreadURLs("))
    #expect(!detailSource.contains("let urls = threadIndex.threads(forPath: file.path)"))
    #expect(!detailSource.contains(".compactMap(\\.url)"))
    #expect(!detailSource.contains("].joined(separator: \":\")"))
  }

  @Test("files detail reuses cached diff documents")
  func filesDetailReusesCachedDiffDocuments() throws {
    let detailSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeDetailPane.swift"
    )
    let contentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffContent.swift"
    )
    let cacheSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffDocumentCache.swift"
    )
    let splitSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffSplit.swift"
    )
    let unifiedSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffUnified.swift"
    )
    let previewSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffPreview.swift"
    )

    // The pane owns the parsed-document cache and hands it to the diff content
    // view, which builds every document through it at the configured tab width.
    #expect(
      detailSource.contains(
        "@State private var documentCache = DashboardReviewFileDiffDocumentCache()"
      )
    )
    #expect(detailSource.contains("documentCache: documentCache"))
    #expect(contentSource.contains("documentCache.document("))
    #expect(contentSource.contains("tabWidth: preferences.snapshot.filesTabWidth"))
    #expect(cacheSource.contains("final class DashboardReviewFileDiffDocumentCache"))
    #expect(splitSource.contains("document: DashboardReviewFileDiffDocument"))
    #expect(unifiedSource.contains("document: DashboardReviewFileDiffDocument"))
    #expect(previewSource.contains("let projectedPatch: ReviewFilePatch"))
    #expect(previewSource.contains("document: document"))
  }

  @Test("file card caches repeated header labels")
  func fileCardCachesRepeatedHeaderLabels() throws {
    let fileCardSource = try dashboardReviewsRouteSource(named: "DashboardReviewFileCard.swift")

    #expect(fileCardSource.contains("private let additionCountLabel: String"))
    #expect(fileCardSource.contains("private let deletionCountLabel: String"))
    #expect(fileCardSource.contains("private let expandAccessibilityLabel: String"))
    #expect(fileCardSource.contains("private let accessibilityLabelText: Text"))
    #expect(!fileCardSource.contains("Text(\"+\\(file.additions)\")"))
    #expect(!fileCardSource.contains("Text(\"-\\(file.deletions)\")"))
    #expect(!fileCardSource.contains("private var accessibilityLabel: Text"))
  }

  @Test("diff grid context menu avoids URL arrays for first thread URL")
  func diffGridContextMenuAvoidsURLArraysForFirstThreadURL() throws {
    let gridSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffGrid+Viewport.swift")

    #expect(gridSource.contains("func firstThreadURL(forRowID rowID: Int) -> String?"))
    #expect(!gridSource.contains("compactMap(\\.url).first"))
  }

  @Test("diff parser streams patch lines without upfront string array")
  func diffParserStreamsPatchLinesWithoutUpfrontStringArray() throws {
    let documentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffDocument.swift"
    )

    #expect(documentSource.contains("private static func forEachPatchLine("))
    #expect(documentSource.contains("body(patch[lineStart..<lineEnd])"))
    #expect(documentSource.contains("rows.reserveCapacity(estimatedLineCount)"))
    #expect(documentSource.contains("longestCodeCharacterCount = parsed.longestCodeCharacterCount"))
    #expect(
      !documentSource.contains(
        ".split(separator: \"\\n\", omittingEmptySubsequences: false).map(String.init)"
      )
    )
    #expect(!documentSource.contains("rows.map(\\.text.count).max()"))
    #expect(!documentSource.contains("private static func splitPatchLines"))
  }

  @Test("review task keys avoid transient colon join arrays")
  func reviewTaskKeysAvoidTransientColonJoinArrays() throws {
    let files = [
      "DashboardReviewConversationFeed.swift",
      "DashboardReviewDetailView.swift",
      "DashboardReviewFilesModeContentPane.swift",
      "DashboardReviewFilesModeDetailPane.swift",
    ]

    for file in files {
      let source = try dashboardReviewsRouteSource(named: file)
      #expect(!source.contains("].joined(separator: \":\")"))
    }
  }

  @Test("visual status sentences avoid transient join arrays")
  func visualStatusSentencesAvoidTransientJoinArrays() throws {
    let visualsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsVisualComponents.swift"
    )

    #expect(visualsSource.contains("private func appendAttentionReason("))
    #expect(!visualsSource.contains("var parts: [String]"))
    #expect(!visualsSource.contains("var reasons: [String]"))
    #expect(!visualsSource.contains("parts.joined(separator: \", \")"))
    #expect(!visualsSource.contains("reasons.joined(separator: \" \")"))
  }

  @Test("provenance labels avoid transient join arrays")
  func provenanceLabelsAvoidTransientJoinArrays() throws {
    let provenanceSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsProvenance.swift"
    )

    #expect(!provenanceSource.contains("parts.joined(separator: \" · \")"))
    #expect(!provenanceSource.contains("repositories.prefix(3).joined(separator: \", \")"))
  }

  @Test("provenance snapshot precomputes body labels")
  func provenanceSnapshotPrecomputesBodyLabels() throws {
    let provenanceSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsProvenance.swift"
    )

    #expect(provenanceSource.contains("let fetchedAgeTitle: String"))
    #expect(provenanceSource.contains("let detailTitle: String"))
    #expect(!provenanceSource.contains("var fetchedAgeTitle: String"))
    #expect(!provenanceSource.contains("var detailTitle: String"))
    #expect(!provenanceSource.contains("localizedString(for: fetchedDate, relativeTo: .now)"))
  }

  @Test("scheduler dispatch keeps per-tick candidate selection bounded")
  func schedulerDispatchKeepsPerTickCandidateSelectionBounded() throws {
    let schedulerSource = try dashboardReviewsRouteSource(named: "DashboardReviewsScheduler.swift")

    #expect(schedulerSource.contains("DashboardReviewsDispatchCandidate"))
    #expect(schedulerSource.contains("insertSortedByDispatchPriority"))
    #expect(schedulerSource.contains("candidates.reserveCapacity(limit + 1)"))
    #expect(!schedulerSource.contains(".filter { !repositoriesInFlight.contains($0) }"))
    #expect(!schedulerSource.contains(".sorted { lhs, rhs in"))
  }

  @Test("repository section header avoids explicit relative formatter work in body")
  func repositorySectionHeaderAvoidsExplicitRelativeFormatterWorkInBody() throws {
    let headerSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRepositorySectionHeader.swift"
    )

    // The header renders relative sync time via a pure-arithmetic label helper,
    // so the body never allocates or runs a relative date formatter.
    #expect(
      headerSource.contains("dashboardReviewsRepositorySectionHeaderRelativeSyncDisplayLabel(")
    )
    #expect(!headerSource.contains("RelativeDateTimeFormatter"))
    #expect(!headerSource.contains("reviewsRelativeFormatter.localizedString"))
    #expect(!headerSource.contains("relativeTo: .now"))
  }

}
