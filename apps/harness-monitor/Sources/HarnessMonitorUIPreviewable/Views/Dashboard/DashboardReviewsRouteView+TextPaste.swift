import AppKit
import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  func pasteReviewTextFromClipboard() {
    let pasteboard = NSPasteboard.general
    let text =
      pasteboard.string(forType: .string)
      ?? pasteboard.string(forType: NSPasteboard.PasteboardType.URL)
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      store.toast.presentWarning("Clipboard does not contain review text")
      return
    }
    trackInFlight(Task { await handlePastedReviewText(text) })
  }

  func handlePastedReviewText(_ text: String) async {
    let policyCenter = AutomationPolicyCenter.shared
    synchronizeEnforcedCanvasAutomationPolicies(policyCenter: policyCenter)
    let references = await Task.detached(priority: .userInitiated) {
      GitHubPullRequestReferenceParser.references(in: text)
    }.value
    let sourceApplication = ClipboardAutomationSourceApplicationResolver.current(
      confidence: "manual-review-text-paste"
    )
    let result = pastedTextPolicyResult(
      text: text,
      references: references,
      sourceApplication: sourceApplication,
      policyCenter: policyCenter
    )
    if let event = result.eventRecord {
      policyCenter.recordAutomationEvent(event)
    }
    guard result.outcome == .matched else {
      store.toast.presentWarning(result.reason ?? "Review text paste was skipped by policy")
      return
    }
    guard !result.reviewPullRequestReferences.isEmpty else {
      store.toast.presentWarning("No GitHub pull request links found")
      return
    }
    let resolution = await resolvePastedReviewReferences(result.reviewPullRequestReferences)
    guard !resolution.items.isEmpty else {
      store.toast.presentWarning("No pasted pull requests matched Reviews data")
      return
    }
    await applyPastedTextPolicyResult(
      result,
      text: text,
      references: result.reviewPullRequestReferences,
      resolution: resolution
    )
  }

  private func pastedTextPolicyResult(
    text: String,
    references: [GitHubPullRequestReference],
    sourceApplication: AutomationSourceApplication?,
    policyCenter: AutomationPolicyCenter
  ) -> AutomationPolicyExecutionResult {
    let contentKinds: Set<AutomationClipboardContentKind> =
      references.isEmpty ? [.text] : [.text, .url]
    let decision = policyCenter.decision(
      for: .manualReviewTextPaste,
      contentKinds: contentKinds,
      sourceApplication: sourceApplication,
      allowsPasteboardPrompt: true
    )
    return AutomationPolicyExecutionPipeline.execute(
      AutomationPolicyExecutionRequest(
        source: .manualReviewTextPaste,
        decision: decision,
        summary: pastedTextSummary(references: references, sourceApplication: sourceApplication),
        contentKinds: contentKinds,
        declaredTypes: [AutomationClipboardContentKind.text.rawValue],
        detectedContentType: AutomationClipboardContentKind.text.rawValue,
        sourceApplication: sourceApplication,
        trigger: "Reviews text paste",
        metadata: ClipboardAutomationMetadataPayload(
          textPreview: String(text.prefix(1_000)),
          filePaths: []
        ),
        reviewPullRequestReferences: references
      )
    )
  }

  private func synchronizeEnforcedCanvasAutomationPolicies(
    policyCenter: AutomationPolicyCenter
  ) {
    guard let document = store.globalTaskBoardPolicyPipeline, document.mode == .enforced else {
      return
    }
    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(document: document)
    guard policyCenter.document.canvasPolicies != compilation.policies else {
      return
    }
    guard !compilation.policies.isEmpty || policyCenter.document.hasCanvasPolicies else {
      return
    }
    policyCenter.replaceCanvasPolicies(compilation.policies)
  }

  private func applyPastedTextPolicyResult(
    _ result: AutomationPolicyExecutionResult,
    text: String,
    references: [GitHubPullRequestReference],
    resolution: DashboardReviewsPastedTextResolution
  ) async {
    let actions = Set(result.executedActions)
    if actions.contains(.previewReviewApprovals) {
      let preview = await reviewActionPreview(.approve, items: resolution.items)
      routePastedTextReviewSheet = DashboardReviewsPastedTextReviewSheetState(
        policyName: result.policyName,
        textPreview: String(text.prefix(1_000)),
        references: references,
        items: resolution.items,
        missingReferences: resolution.missingReferences,
        approvalPreview: preview,
        offersAutoPolicy: actions.contains(.runReviewPolicy),
        dryRun: result.shouldDryRunReviewApprovals
      )
      return
    }
    if actions.contains(.promptReviewApprovals) {
      routePendingActionConfirmation = pastedReviewApprovalConfirmation(
        items: resolution.items,
        missingReferences: resolution.missingReferences,
        dryRun: result.shouldDryRunReviewApprovals
      )
      return
    }
    if actions.contains(.runReviewPolicy) {
      await performReviewAction(.auto, items: resolution.items)
      return
    }
    if actions.contains(.approveReviewPullRequests) {
      enqueuePastedReviewApproval(
        items: resolution.items,
        dryRun: result.shouldDryRunReviewApprovals
      )
      return
    }
    routeSelectedIDs = Set(resolution.items.map(\.pullRequestID))
    store.toast.presentSuccess("Selected \(resolution.items.count) pasted pull request(s)")
  }

  private func resolvePastedReviewReferences(
    _ references: [GitHubPullRequestReference]
  ) async -> DashboardReviewsPastedTextResolution {
    var itemByReference = indexedReviewItems(routeResponse.items)
    let missingBeforeFetch = references.filter { itemByReference[$0.id] == nil }
    if !missingBeforeFetch.isEmpty, let client = store.apiClient {
      await fetchPastedReviewRepositories(missingBeforeFetch, client: client)
      itemByReference = indexedReviewItems(routeResponse.items)
    }
    let items = references.compactMap { itemByReference[$0.id] }
    let foundIDs = Set(items.map { "\($0.repository.lowercased())#\($0.number)" })
    return DashboardReviewsPastedTextResolution(
      items: items,
      missingReferences: references.filter { !foundIDs.contains($0.id) }
    )
  }

  private func fetchPastedReviewRepositories(
    _ references: [GitHubPullRequestReference],
    client: any HarnessMonitorClientProtocol
  ) async {
    let repositories = orderedUnique(references.map(\.repository))
    do {
      let response = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.queryReviews(
          request: ReviewsQueryRequest(
            repositories: repositories,
            forceRefresh: true,
            cacheMaxAgeSeconds: 0
          )
        )
      }
      mergePastedReviewResponse(response, repositories: repositories)
    } catch {
      store.toast.presentWarning("Could not refresh pasted PRs: \(error.localizedDescription)")
    }
  }

  private func mergePastedReviewResponse(
    _ response: ReviewsQueryResponse,
    repositories: [String]
  ) {
    let normalized = HarnessMonitorReviewsDaemonNormalizer.normalize(
      response: response,
      daemonWireVersion: store.health?.wireVersion
    )
    let itemsByRepository = Dictionary(grouping: normalized.items) { item in
      item.repository.lowercased()
    }
    var currentItems = routeResponse.items
    var mergedLabels = routeResponse.repositoryLabels
    for repository in repositories {
      let repoItems = itemsByRepository[repository.lowercased()] ?? []
      let repoResponse = ReviewsQueryResponse(
        fetchedAt: normalized.fetchedAt,
        fromCache: normalized.fromCache,
        summary: ReviewsSummary(items: repoItems),
        items: repoItems,
        repositoryLabels: normalized.repositoryLabels,
        viewerLogin: normalized.viewerLogin
      )
      currentItems = ReviewsCache.applyPerRepoResponseToItems(
        currentItems,
        repository: repository,
        response: repoResponse
      )
      if let labels = normalized.repositoryLabels[repository], !labels.isEmpty {
        mergedLabels[repository] = labels
      }
    }
    setRouteResponse(
      ReviewsQueryResponse(
        fetchedAt: normalized.fetchedAt,
        fromCache: routeResponse.fromCache,
        summary: ReviewsSummary(items: currentItems),
        items: currentItems,
        repositoryLabels: mergedLabels,
        viewerLogin: normalized.viewerLogin ?? routeResponse.viewerLogin
      ),
      bumpsItemsRevision: currentItems != routeResponse.items
    )
  }

  private func pastedReviewApprovalConfirmation(
    items: [ReviewItem],
    missingReferences: [GitHubPullRequestReference],
    dryRun: Bool
  ) -> DashboardReviewActionConfirmation {
    let actionableCount = items.count(where: \.canAttemptManualApproval)
    let missingText =
      missingReferences.isEmpty
      ? ""
      : "\n\n\(missingReferences.count) pasted link(s) were not found in Reviews data."
    let verb = dryRun ? "Dry run approval for" : "Approve"
    let title = dryRun ? "Dry run pasted pull request approvals?" : "Approve pasted pull requests?"
    let buttonTitle =
      actionableCount == 1
      ? "\(dryRun ? "Dry Run" : "Approve") 1 PR"
      : "\(dryRun ? "Dry Run" : "Approve") \(actionableCount) PRs"
    return DashboardReviewActionConfirmation(
      action: .approve,
      pullRequestIDs: items.map(\.pullRequestID),
      title: title,
      message:
        "\(verb) \(actionableCount) of \(items.count) pasted pull request(s).\(missingText)",
      confirmButtonTitle: buttonTitle,
      confirmRole: nil,
      approvalSubmission: .queued(dryRun: dryRun)
    )
  }

  private func indexedReviewItems(_ items: [ReviewItem]) -> [String: ReviewItem] {
    var itemByReference: [String: ReviewItem] = [:]
    itemByReference.reserveCapacity(items.count)
    for item in items {
      itemByReference["\(item.repository.lowercased())#\(item.number)"] = item
    }
    return itemByReference
  }

  private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0.lowercased()).inserted }
  }

  private func pastedTextSummary(
    references: [GitHubPullRequestReference],
    sourceApplication: AutomationSourceApplication?
  ) -> String {
    let count = references.count
    let appName = sourceApplication?.displayName ?? "Unknown app"
    return "\(count) GitHub pull request link\(count == 1 ? "" : "s") from \(appName)"
  }
}
