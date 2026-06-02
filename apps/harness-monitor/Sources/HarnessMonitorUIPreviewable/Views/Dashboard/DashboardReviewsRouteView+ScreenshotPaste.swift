import AppKit
import HarnessMonitorKit

extension DashboardReviewsRouteView {
  func consumePendingReviewScreenshotPasteRequest() {
    guard let request = DashboardReviewsScreenshotPasteboardRequests.takePendingRequest(
      after: routeHandledScreenshotPasteboardRequestID
    ) else {
      return
    }
    routeHandledScreenshotPasteboardRequestID = request.id
    trackInFlight(Task { await handleReviewScreenshotPaste(request) })
  }

  func handleReviewScreenshotPaste(_ request: DashboardReviewsScreenshotPasteboardRequest) async {
    guard !request.candidates.isEmpty else {
      store.toast.presentWarning("Clipboard does not contain review screenshots")
      return
    }
    let policyCenter = AutomationPolicyCenter.shared
    synchronizeEnforcedCanvasAutomationPolicies(policyCenter: policyCenter)
    let sourceApplication = ClipboardAutomationSourceApplicationResolver.current(
      confidence: "manual-review-screenshot-paste"
    )
    let decision = policyCenter.decision(
      for: .reviewScreenshotPaste,
      contentKinds: [.image],
      sourceApplication: sourceApplication,
      allowsPasteboardPrompt: true
    )
    let configuration = decision.policy.reviewPullRequestExtraction
      ?? ReviewPullRequestExtractionConfiguration()
    let ocrConfiguration = decision.policy.ocrConfiguration
      ?? AutomationPolicyOCRConfiguration()
    let recognition = await recognizeReviewScreenshotCandidates(
      request.candidates,
      configuration: ocrConfiguration
    )
    let references = resolvedReferences(from: recognition.rows)
    let result = reviewScreenshotPolicyResult(
      request: request,
      rows: recognition.rows,
      recognizedText: recognition.text,
      sourceApplication: sourceApplication,
      decision: decision
    )
    if let event = result.eventRecord {
      policyCenter.recordAutomationEvent(event)
    }
    guard result.outcome == .matched else {
      store.toast.presentWarning(result.reason ?? "Review screenshot paste was skipped by policy")
      return
    }
    guard !recognition.rows.isEmpty else {
      store.toast.presentWarning("No pull request rows found in screenshot")
      return
    }
    let extraction = await resolveReviewScreenshotRows(
      recognition.rows,
      configuration: configuration
    )
    if configuration.autoCopy,
      result.executedActions.contains(.copyReviewPullRequestList),
      !extraction.outputText.isEmpty
    {
      HarnessMonitorClipboard.copy(extraction.outputText)
      store.toast.presentSuccess("Copied \(extraction.selectedItems.count) pull request(s)")
    }
    if configuration.showSheet || result.executedActions.contains(.previewReviewApprovals) {
      await presentReviewScreenshotExtractionSheet(
        result: result,
        textPreview: recognition.text,
        references: references,
        extraction: extraction
      )
    } else if extraction.outputText.isEmpty {
      store.toast.presentWarning("No resolved pull requests matched the configured scope")
    }
  }

  private func recognizeReviewScreenshotCandidates(
    _ candidates: [DashboardOCRImageCandidate],
    configuration: AutomationPolicyOCRConfiguration
  ) async -> (text: String, rows: [ReviewPullRequestExtractionRow]) {
    var texts: [String] = []
    var rows: [ReviewPullRequestExtractionRow] = []
    for candidate in candidates {
      let result = await DashboardOCRRecognizer.recognizeText(
        in: candidate.image,
        configuration: configuration
      )
      if !result.text.isEmpty {
        texts.append(result.text)
      }
      let parsedRows = ReviewScreenshotPullRequestParser.rows(
        from: result,
        image: candidate.image
      )
      rows.append(contentsOf: reindexedRows(parsedRows, startingAt: rows.count))
    }
    return (texts.joined(separator: "\n\n"), rows)
  }

  private func reviewScreenshotPolicyResult(
    request: DashboardReviewsScreenshotPasteboardRequest,
    rows: [ReviewPullRequestExtractionRow],
    recognizedText: String,
    sourceApplication: AutomationSourceApplication?,
    decision: AutomationPolicyDecision
  ) -> AutomationPolicyExecutionResult {
    AutomationPolicyExecutionPipeline.execute(
      AutomationPolicyExecutionRequest(
        source: .reviewScreenshotPaste,
        decision: decision,
        summary: reviewScreenshotSummary(rowCount: rows.count, sourceApplication: sourceApplication),
        contentKinds: rows.isEmpty ? [.image] : [.image, .text, .url],
        declaredTypes: [AutomationClipboardContentKind.image.rawValue],
        detectedContentType: AutomationClipboardContentKind.image.rawValue,
        sourceApplication: sourceApplication,
        trigger: "Reviews screenshot paste",
        metadata: ClipboardAutomationMetadataPayload(
          textPreview: String(recognizedText.prefix(1_000)),
          filePaths: request.candidates.flatMap(\.sourceMetadata).copyableFilePaths
        ),
        imageCandidates: request.candidates,
        reviewPullRequestReferences: resolvedReferences(from: rows),
        reviewPullRequestCandidateCount: rows.count
      )
    )
  }

  private func resolveReviewScreenshotRows(
    _ rows: [ReviewPullRequestExtractionRow],
    configuration: ReviewPullRequestExtractionConfiguration
  ) async -> ReviewPullRequestExtractionResult {
    await ReviewPullRequestExtractionService.resolve(
      rows: rows,
      context: ReviewPullRequestExtractionContext(
        currentItems: routeResponse.items,
        configuredRepositories: configuredReviewExtractionRepositories(configuration),
        activeReviewsRepository: primaryDetailItem?.repository,
        configuration: configuration,
        fetchRepositories: { repositories in
          guard let client = store.apiClient else { return [] }
          return await fetchPastedReviewRepositories(repositories, client: client)
        }
      )
    )
  }

  private func presentReviewScreenshotExtractionSheet(
    result: AutomationPolicyExecutionResult,
    textPreview: String,
    references: [GitHubPullRequestReference],
    extraction: ReviewPullRequestExtractionResult
  ) async {
    let allowsApprovalActions = result.executedActions.contains {
      Self.reviewScreenshotApprovalActions.contains($0)
    }
    let preview =
      allowsApprovalActions
      ? await reviewActionPreview(.approve, items: extraction.selectedItems)
      : ReviewsActionPreviewResponse(
        action: .approve,
        totalCount: extraction.selectedItems.count,
        actionableCount: 0,
        skippedCount: extraction.selectedItems.count
      )
    routePastedTextReviewSheet = DashboardReviewsPastedTextReviewSheetState(
      policyName: result.policyName,
      textPreview: String(textPreview.prefix(1_000)),
      references: references,
      items: extraction.matchedItems,
      missingReferences: [],
      extractionRows: extraction.rows,
      outputText: extraction.outputText,
      approvalPreview: preview,
      offersAutoPolicy: result.executedActions.contains(.runReviewPolicy),
      dryRun: result.policyDecision.policy.isDryRun,
      allowsApprovalActions: allowsApprovalActions
    )
  }

  private func reindexedRows(
    _ rows: [ReviewPullRequestExtractionRow],
    startingAt offset: Int
  ) -> [ReviewPullRequestExtractionRow] {
    rows.enumerated().map { index, row in
      ReviewPullRequestExtractionRow(
        rowIndex: offset + index,
        reference: row.reference,
        text: row.text,
        titleText: row.titleText,
        branchText: row.branchText,
        visualStatus: row.visualStatus,
        normalizedBoundingBox: row.normalizedBoundingBox
      )
    }
  }

  private func resolvedReferences(
    from rows: [ReviewPullRequestExtractionRow]
  ) -> [GitHubPullRequestReference] {
    var seen = Set<String>()
    return rows.compactMap { row -> GitHubPullRequestReference? in
      guard case .resolved(let reference) = row.reference else { return nil }
      return seen.insert(reference.id).inserted ? reference : nil
    }
  }

  private func reviewScreenshotSummary(
    rowCount: Int,
    sourceApplication: AutomationSourceApplication?
  ) -> String {
    let appName = sourceApplication?.displayName ?? "Unknown app"
    return "\(rowCount) screenshot pull request row\(rowCount == 1 ? "" : "s") from \(appName)"
  }

  private static let reviewScreenshotApprovalActions: Set<AutomationPolicyAction> = [
    .promptReviewApprovals,
    .approveReviewPullRequests,
    .runReviewPolicy,
  ]
}
