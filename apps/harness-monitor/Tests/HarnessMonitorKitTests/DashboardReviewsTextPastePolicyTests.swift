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

  @Test("Default document enables manual review text paste policy")
  func defaultDocumentEnablesManualReviewTextPastePolicy() {
    let document = AutomationPolicyDocument()
    let policy = document.policy(for: .manualReviewTextPaste)

    #expect(policy.id == "reviews.text-paste")
    #expect(policy.isEnabled)
    #expect(policy.match.contentKinds == [.text, .url])
    #expect(policy.preprocessors == [.normalizeGitHubPullRequestLinks, .dedupePullRequests])
    #expect(policy.actions.contains(.extractGitHubPullRequests))
    #expect(policy.actions.contains(.previewReviewApprovals))
    #expect(policy.actions.contains(.promptReviewApprovals))
  }

  @Test("Default document enables review screenshot paste extraction policy")
  func defaultDocumentEnablesReviewScreenshotPasteExtractionPolicy() throws {
    let document = AutomationPolicyDocument()
    let policy = document.policy(for: .reviewScreenshotPaste)
    let extraction = try #require(policy.reviewPullRequestExtraction)

    #expect(policy.id == "reviews.screenshot-paste")
    #expect(policy.isEnabled)
    #expect(policy.match.contentKinds == [.image])
    #expect(policy.actions.contains(.ocrImage))
    #expect(policy.actions.contains(.resolveReviewPullRequests))
    #expect(policy.actions.contains(.copyReviewPullRequestList))
    #expect(policy.ocrConfiguration == AutomationPolicyOCRConfiguration())
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

    #expect(rows.map(\.reference.displayText) == [
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

  @Test("Policy binding config round trips through Swift graph JSON")
  func policyBindingConfigRoundTripsThroughSwiftGraphJSON() throws {
    var binding = TaskBoardPolicyPipelineAutomationBinding.canvasDefault(
      source: .reviewScreenshotPaste
    )
    binding.ocrConfiguration = TaskBoardPolicyPipelineOCRConfiguration(
      recognitionLevel: "fast",
      automaticallyDetectsLanguage: false,
      usesLanguageCorrection: false
    )
    binding.reviewPullRequestExtraction = TaskBoardPolicyPipelineReviewPullRequestExtraction(
      repositoryMode: "policyRepositories",
      policyRepositories: ["kong/kuma"],
      numberMemoryEnabled: false,
      resultScope: "failing",
      failureSignalMode: "visualScreenshot",
      outputFormat: "markdownLinks",
      autoCopy: false,
      showSheet: true
    )

    let data = try JSONEncoder().encode(binding)
    let decoded = try JSONDecoder().decode(
      TaskBoardPolicyPipelineAutomationBinding.self,
      from: data
    )

    #expect(decoded.ocrConfiguration?.recognitionLevel == "fast")
    #expect(decoded.reviewPullRequestExtraction?.repositoryMode == "policyRepositories")
    #expect(decoded.reviewPullRequestExtraction?.policyRepositories == ["kong/kuma"])
    #expect(decoded.reviewPullRequestExtraction?.outputFormat == "markdownLinks")
  }

  @Test("Policy execution exposes pasted review actions and audit references")
  func policyExecutionExposesPastedReviewActionsAndAuditReferences() throws {
    let policy = AutomationPolicyDocument.defaultPolicy(for: .manualReviewTextPaste)
    let references = GitHubPullRequestReferenceParser.references(
      in: "approve https://github.com/kong/kuma/pull/16703/files")
    let request = AutomationPolicyExecutionRequest(
      source: .manualReviewTextPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "1 GitHub pull request link from Slack",
      contentKinds: [.text, .url],
      declaredTypes: ["public.utf8-plain-text"],
      detectedContentType: "public.utf8-plain-text",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(
        textPreview: "https://github.com/kong/kuma/pull/16703/files",
        filePaths: []
      ),
      reviewPullRequestReferences: references
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)
    let event = try #require(result.eventRecord)

    #expect(result.outcome == .matched)
    #expect(result.reviewPullRequestReferences.map(\.displayText) == ["kong/kuma#16703"])
    #expect(result.executedActions == policy.actions)
    #expect(event.reviewPullRequests == ["kong/kuma#16703"])
    #expect(event.textPreview == "https://github.com/kong/kuma/pull/16703/files")
  }

  @Test("Policy execution carries dry run approval intent from the policy")
  func policyExecutionCarriesDryRunApprovalIntentFromPolicy() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualReviewTextPaste)
    policy.dryRun = true
    let references = GitHubPullRequestReferenceParser.references(
      in: "https://github.com/kong/kuma/pull/16703")
    let request = AutomationPolicyExecutionRequest(
      source: .manualReviewTextPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "1 GitHub pull request link from Slack",
      contentKinds: [.text, .url],
      declaredTypes: ["public.utf8-plain-text"],
      detectedContentType: "public.utf8-plain-text",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(
        textPreview: "https://github.com/kong/kuma/pull/16703",
        filePaths: []
      ),
      reviewPullRequestReferences: references
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.shouldDryRunReviewApprovals)
  }

  @Test("Policy execution runs screenshot PR actions from OCR row candidates")
  func policyExecutionRunsScreenshotPRActionsFromOCRRowCandidates() {
    let policy = AutomationPolicyDocument.defaultPolicy(for: .reviewScreenshotPaste)
    let request = AutomationPolicyExecutionRequest(
      source: .reviewScreenshotPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "1 screenshot row",
      contentKinds: [.image],
      declaredTypes: ["public.image"],
      detectedContentType: "public.image",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(textPreview: "#9845", filePaths: []),
      imageCandidates: [
        DashboardOCRImageCandidate(
          image: NSImage(size: NSSize(width: 1, height: 1)),
          sourceName: "screenshot.png",
          sourceDetail: nil,
          fingerprint: "test-image"
        )
      ],
      reviewPullRequestCandidateCount: 1
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.executedActions.contains(.ocrImage))
    #expect(result.executedActions.contains(.extractGitHubPullRequests))
    #expect(result.executedActions.contains(.resolveReviewPullRequests))
    #expect(result.executedActions.contains(.copyReviewPullRequestList))
  }

  @Test("Policy execution skips review actions when no PR links are present")
  func policyExecutionSkipsReviewActionsWhenNoPRLinksArePresent() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualReviewTextPaste)
    policy.actions = [.extractGitHubPullRequests, .approveReviewPullRequests]
    let request = AutomationPolicyExecutionRequest(
      source: .manualReviewTextPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "No links",
      contentKinds: [.text],
      declaredTypes: ["public.utf8-plain-text"],
      detectedContentType: "public.utf8-plain-text",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(textPreview: "hello", filePaths: [])
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .skipped)
    #expect(result.reason == "No GitHub pull request links found")
    #expect(result.skippedActions == [.extractGitHubPullRequests, .approveReviewPullRequests])
  }

  private static func resolveRows(
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

  private static func bareRow(index: Int, number: UInt64) -> ReviewPullRequestExtractionRow {
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

  private static func resolvedRow(
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

  private static func reviewItem(
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
