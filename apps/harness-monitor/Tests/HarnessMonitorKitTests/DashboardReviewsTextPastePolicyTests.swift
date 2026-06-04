import AppKit
import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard Reviews text paste policies")
@MainActor
struct DashboardReviewsTextPastePolicyTests {
  @Test("Parser extracts and dedupes GitHub PR links from noisy pasted text")
  func parserExtractsAndDedupesNoisyGitHubPRLinks() {
    let text = """
      Ania 10:42 AM
      <https://github.com/kong/kuma/pull/16703/files#diff-abc|PR>
      date: 2026-05-29
      https: //github. com/smykla-skalski/harness/pull/1234 /files#discussion_r99
      random url https://example.invalid/not-a-pr
      kong/kuma#16703
      """

    let references = GitHubPullRequestReferenceParser.references(in: text)

    #expect(
      references.map(\.displayText) == [
        "kong/kuma#16703",
        "smykla-skalski/harness#1234",
      ])
    #expect(references[0].canonicalURLString == "https://github.com/kong/kuma/pull/16703")
  }

  @Test("Default document leaves manual review text paste to policy canvas")
  func defaultDocumentLeavesManualReviewTextPasteToPolicyCanvas() {
    let document = AutomationPolicyDocument()
    let fallbackPolicy = AutomationPolicyDocument.defaultPolicy(for: .manualReviewTextPaste)

    #expect(document.policies(for: .manualReviewTextPaste).isEmpty)
    #expect(!fallbackPolicy.isEnabled)
    #expect(fallbackPolicy.match.contentKinds == [.text, .url])
    #expect(
      fallbackPolicy.preprocessors == [.normalizeGitHubPullRequestLinks, .dedupePullRequests]
    )
    #expect(fallbackPolicy.actions.contains(.extractGitHubPullRequests))
    #expect(fallbackPolicy.actions.contains(.previewReviewApprovals))
    #expect(fallbackPolicy.actions.contains(.promptReviewApprovals))
  }

  @Test("Default document leaves review screenshot paste to policy canvas")
  func defaultDocumentLeavesReviewScreenshotPasteToPolicyCanvas() throws {
    let document = AutomationPolicyDocument()
    let fallbackPolicy = AutomationPolicyDocument.defaultPolicy(for: .reviewScreenshotPaste)
    let extraction = try #require(fallbackPolicy.reviewPullRequestExtraction)

    #expect(document.policies(for: .reviewScreenshotPaste).isEmpty)
    #expect(!fallbackPolicy.isEnabled)
    #expect(fallbackPolicy.match.contentKinds == [.image])
    #expect(fallbackPolicy.actions.contains(.ocrImage))
    #expect(fallbackPolicy.actions.contains(.resolveReviewPullRequests))
    #expect(fallbackPolicy.actions.contains(.copyReviewPullRequestList))
    #expect(fallbackPolicy.ocrConfiguration == AutomationPolicyOCRConfiguration())
    #expect(extraction.repositoryMode == .allConfiguredRepos)
    #expect(extraction.failureSignalMode == .liveOrVisual)
    #expect(extraction.outputFormat == .newlineGitHubURLs)
    #expect(extraction.autoCopy)
    #expect(extraction.showSheet)
  }

  @Test("Screenshot parser extracts ordered rows from noisy GitHub PR transcript")
  func screenshotParserExtractsOrderedRowsFromNoisyTranscript() {
    let result = DashboardOCRRecognitionResult(
      text: """
        passed kong/kuma#16703 Fix mesh sync
        random channel text
        failed #9845 unblock policy canvas
        https://github.com/smykla-skalski/harness/pull/1234/files checks failing
        """,
      observations: [],
      errorMessage: nil
    )

    let rows = ReviewScreenshotPullRequestParser.rows(from: result)

    #expect(
      rows.map(\.reference.displayText) == [
        "kong/kuma#16703",
        "#9845",
        "smykla-skalski/harness#1234",
      ])
    #expect(rows.map(\.visualStatus) == [.passing, .failing, .failing])
    #expect(rows[1].titleText.contains("unblock policy canvas"))
  }

  @Test("Bare number resolution queries configured repositories and dedupes copied output")
  func bareNumberResolutionQueriesConfiguredRepositoriesAndDedupesOutput() async {
    await ReviewPullRequestExtractionService.resetNumberMemoryForTesting()
    var fetchedRepositories: [String] = []
    let rows = [
      Self.bareRow(index: 0, number: 9845),
      Self.bareRow(index: 1, number: 9845),
    ]
    let configuration = ReviewPullRequestExtractionConfiguration()

    let result = await ReviewPullRequestExtractionService.resolve(
      rows: rows,
      context: ReviewPullRequestExtractionContext(
        currentItems: [],
        configuredRepositories: ["kong/kuma", "smykla-skalski/harness", "kong/kuma"],
        activeReviewsRepository: nil,
        configuration: configuration,
        fetchRepositories: { repositories in
          fetchedRepositories = repositories
          return [Self.reviewItem(repository: "smykla-skalski/harness", number: 9845)]
        }
      )
    )

    #expect(fetchedRepositories == ["kong/kuma", "smykla-skalski/harness"])
    #expect(result.matchedItems.map(\.pullRequestID) == ["smykla-skalski/harness#9845"])
    #expect(
      result.outputText == "https://github.com/smykla-skalski/harness/pull/9845"
    )
  }

  @Test("Learned number memory accelerates lookup but does not invent unverified matches")
  func learnedNumberMemoryDoesNotInventUnverifiedMatches() async {
    await ReviewPullRequestExtractionService.resetNumberMemoryForTesting()
    let known = Self.reviewItem(repository: "kong/kuma", number: 1234)
    _ = await ReviewPullRequestExtractionService.resolve(
      rows: [Self.resolvedRow(index: 0, item: known)],
      context: ReviewPullRequestExtractionContext(
        currentItems: [known],
        configuredRepositories: [],
        activeReviewsRepository: nil,
        configuration: ReviewPullRequestExtractionConfiguration(),
        fetchRepositories: nil
      )
    )
    var fetchedRepositories: [String] = []

    let result = await ReviewPullRequestExtractionService.resolve(
      rows: [Self.bareRow(index: 0, number: 1234)],
      context: ReviewPullRequestExtractionContext(
        currentItems: [],
        configuredRepositories: [],
        activeReviewsRepository: nil,
        configuration: ReviewPullRequestExtractionConfiguration(),
        fetchRepositories: { repositories in
          fetchedRepositories = repositories
          return []
        }
      )
    )

    #expect(fetchedRepositories == ["kong/kuma"])
    #expect(result.matchedItems.isEmpty)
    #expect(result.missingRows.map(\.row.reference.displayText) == ["#1234"])
  }

  @Test("Failing filter honors live visual and live-or-visual modes")
  func failingFilterHonorsConfiguredFailureSignal() async {
    await ReviewPullRequestExtractionService.resetNumberMemoryForTesting()
    let liveFailing = Self.reviewItem(
      repository: "kong/kuma",
      number: 10,
      checkStatus: .failure
    )
    let visualFailing = Self.reviewItem(repository: "kong/kuma", number: 11)
    let rows = [
      Self.resolvedRow(index: 0, item: liveFailing, visualStatus: .passing),
      Self.resolvedRow(index: 1, item: visualFailing, visualStatus: .failing),
    ]

    let liveOnly = await Self.resolveRows(
      rows,
      items: [liveFailing, visualFailing],
      configuration: ReviewPullRequestExtractionConfiguration(
        resultScope: .failing,
        failureSignalMode: .liveReviews
      )
    )
    let visualOnly = await Self.resolveRows(
      rows,
      items: [liveFailing, visualFailing],
      configuration: ReviewPullRequestExtractionConfiguration(
        resultScope: .failing,
        failureSignalMode: .visualScreenshot
      )
    )
    let liveOrVisual = await Self.resolveRows(
      rows,
      items: [liveFailing, visualFailing],
      configuration: ReviewPullRequestExtractionConfiguration(
        resultScope: .failing,
        failureSignalMode: .liveOrVisual
      )
    )

    #expect(liveOnly.selectedItems.map(\.number) == [10])
    #expect(visualOnly.selectedItems.map(\.number) == [11])
    #expect(liveOrVisual.selectedItems.map(\.number) == [10, 11])
  }

  @Test("Output formatter copies only selected resolved refs in configured format")
  func outputFormatterCopiesOnlySelectedResolvedRefs() async {
    await ReviewPullRequestExtractionService.resetNumberMemoryForTesting()
    let passing = Self.reviewItem(repository: "kong/kuma", number: 20)
    let failing = Self.reviewItem(
      repository: "smykla-skalski/harness",
      number: 21,
      checkStatus: .failure
    )
    let rows = [
      Self.resolvedRow(index: 0, item: passing),
      Self.resolvedRow(index: 1, item: failing),
      Self.bareRow(index: 2, number: 404),
    ]

    let result = await Self.resolveRows(
      rows,
      items: [passing, failing],
      configuration: ReviewPullRequestExtractionConfiguration(
        resultScope: .failing,
        outputFormat: .markdownLinks
      )
    )

    #expect(
      result.outputText
        == "[smykla-skalski/harness#21](https://github.com/smykla-skalski/harness/pull/21)"
    )
  }

  fileprivate static func resolveRows(
    _ rows: [ReviewPullRequestExtractionRow],
    items: [ReviewItem],
    configuration: ReviewPullRequestExtractionConfiguration
  ) async -> ReviewPullRequestExtractionResult {
    await ReviewPullRequestExtractionService.resolve(
      rows: rows,
      context: ReviewPullRequestExtractionContext(
        currentItems: items,
        configuredRepositories: [],
        activeReviewsRepository: nil,
        configuration: configuration,
        fetchRepositories: nil
      )
    )
  }

  fileprivate static func bareRow(index: Int, number: UInt64) -> ReviewPullRequestExtractionRow {
    ReviewPullRequestExtractionRow(
      rowIndex: index,
      reference: .bare(number: number, rawMatch: "#\(number)"),
      text: "#\(number)",
      titleText: "",
      branchText: "",
      visualStatus: .unknown,
      normalizedBoundingBox: nil
    )
  }

  fileprivate static func resolvedRow(
    index: Int,
    item: ReviewItem,
    visualStatus: ReviewScreenshotVisualStatus = .unknown
  ) -> ReviewPullRequestExtractionRow {
    ReviewPullRequestExtractionRow(
      rowIndex: index,
      reference: .resolved(
        GitHubPullRequestReference(
          repository: item.repository,
          number: item.number,
          rawMatch: "\(item.repository)#\(item.number)"
        )
      ),
      text: "\(item.repository)#\(item.number)",
      titleText: item.title,
      branchText: "",
      visualStatus: visualStatus,
      normalizedBoundingBox: nil
    )
  }

  fileprivate static func reviewItem(
    repository: String,
    number: UInt64,
    checkStatus: ReviewCheckStatus = .success
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: "\(repository)#\(number)",
      repositoryID: repository,
      repository: repository,
      number: number,
      title: "PR \(number)",
      url: "https://github.com/\(repository)/pull/\(number)",
      authorLogin: "bart",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: checkStatus,
      policyBlocked: false,
      isDraft: false,
      headSha: "sha-\(number)",
      additions: 1,
      deletions: 0,
      createdAt: "2026-06-02T00:00:00Z",
      updatedAt: "2026-06-02T00:00:00Z"
    )
  }
}
