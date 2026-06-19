import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

  @Test("review row avoids per-row hover tracking on the scroll path")
  func reviewRowAvoidsPerRowHoverTrackingOnTheScrollPath() throws {
    let wrapperSource = try dashboardReviewsRouteSource(named: "DashboardReviewRow.swift")
    let rowSource = try dashboardReviewsRouteSource(named: "DashboardReviewListRow.swift")
    let iconSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewListRow+AttentionIcons.swift"
    )

    #expect(!wrapperSource.contains("@State private var isHovered = false"))
    #expect(!wrapperSource.contains(".onHover { hovering in"))
    #expect(wrapperSource.contains(".equatable()"))
    #expect(rowSource.contains("struct DashboardReviewListRow: View, Equatable"))
    #expect(rowSource.contains("static func =="))
    #expect(!rowSource.contains("@State private var isHovered"))
    #expect(!rowSource.contains(".onHover { hovering in"))
    #expect(!iconSource.contains("@State private var isHovered = false"))
    #expect(!iconSource.contains(".onHover { hovering in"))
  }

}

@Suite("DashboardReviewAttentionBadges Tests")
struct DashboardReviewAttentionBadgesTests {
  private func makeTestReviewItem(createdAt: String) -> ReviewItem {
    ReviewItem(
      pullRequestID: "pr-1",
      repositoryID: "repo-1",
      repository: "org-a/example",
      number: 42,
      title: "Bump dependency",
      url: "https://github.com/org-a/example/pull/42",
      authorLogin: "renovate[bot]",
      authorAvatarURL: nil,
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      labels: [],
      checks: [],
      reviews: [],
      additions: 10,
      deletions: 4,
      createdAt: createdAt,
      updatedAt: "2026-05-20T11:00:00Z",
      requiredFailedCheckNames: [],
      viewerCanUpdate: false,
      viewerCanMergeAsAdmin: false
    )
  }

  @Test("Identifies SLA breach correctly")
  func testSlaBreach() {
    let calendar = Calendar.current
    let now = Date()

    // Create a date 50 hours ago
    guard let createdDate = calendar.date(byAdding: .hour, value: -50, to: now) else {
      Issue.record("Could not create test date")
      return
    }

    let formatter = ISO8601DateFormatter()
    let item = makeTestReviewItem(createdAt: formatter.string(from: createdDate))

    // Test with 48h threshold -> should breach
    var badges = DashboardReviewAttentionBadges(item: item, slaThresholdHours: 48, currentDate: now)
    #expect(badges.hasSlaBreach)
    #expect(badges.kinds.contains(DashboardReviewAttentionBadgeKind.slaBreached))

    // Test with 72h threshold -> should NOT breach
    badges = DashboardReviewAttentionBadges(item: item, slaThresholdHours: 72, currentDate: now)
    #expect(!badges.hasSlaBreach)
    #expect(!badges.kinds.contains(DashboardReviewAttentionBadgeKind.slaBreached))

    // Test with nil threshold -> should NOT breach
    badges = DashboardReviewAttentionBadges(item: item, slaThresholdHours: nil, currentDate: now)
    #expect(!badges.hasSlaBreach)

    // Test with 0 threshold -> should NOT breach
    badges = DashboardReviewAttentionBadges(item: item, slaThresholdHours: 0, currentDate: now)
    #expect(!badges.hasSlaBreach)
  }
}
