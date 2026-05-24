import Testing

@Suite("Dashboard reviews body allocation contracts")
struct DashboardReviewsBodyAllocationContractTests {
  @Test("body paths avoid transient ForEach arrays")
  func bodyPathsAvoidTransientForEachArrays() throws {
    let files = [
      "DashboardReviewCheckList.swift",
      "DashboardReviewFilesSection.swift",
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

    #expect(checkListSource.contains("DashboardReviewCheckListPresentation("))
    #expect(!checkListSource.contains("Array(nonProblemChecks.prefix"))
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

    #expect(filesModeSource.contains("files.reserveCapacity(viewModel.filteredFiles.count)"))
    #expect(!filesModeSource.contains("viewModel.filteredFiles.filter { file in"))
  }

  @Test("files navigator row caches repeated body facts")
  func filesNavigatorRowCachesRepeatedBodyFacts() throws {
    let filesModeSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeContentPane.swift"
    )

    #expect(filesModeSource.contains("private let fileName: String"))
    #expect(filesModeSource.contains("private let hasUnresolvedThreads: Bool"))
    #expect(filesModeSource.contains("private let changeCountLabel: String"))
    #expect(!filesModeSource.contains("if threads.contains(where: { !$0.isResolved })"))
  }
}
