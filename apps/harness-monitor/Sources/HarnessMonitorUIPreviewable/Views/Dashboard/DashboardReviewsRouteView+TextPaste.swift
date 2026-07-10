import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
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
    let handleInterval = DashboardReviewsTextPasteTrace.beginHandle(textLength: text.count)
    defer { DashboardReviewsTextPasteTrace.end(handleInterval) }
    let policyCenter = AutomationPolicyCenter.shared
    do {
      let interval = DashboardReviewsTextPasteTrace.beginPreparePolicyRuntime()
      defer { DashboardReviewsTextPasteTrace.end(interval) }
      await preparePastedReviewTextPolicyRuntime(policyCenter: policyCenter)
    }
    let references: [GitHubPullRequestReference]
    do {
      let interval = DashboardReviewsTextPasteTrace.beginParseReferences(textLength: text.count)
      defer { DashboardReviewsTextPasteTrace.end(interval) }
      references = await Task.detached(priority: .userInitiated) {
        GitHubPullRequestReferenceParser.references(in: text)
      }.value
    }
    let sourceApplication = ClipboardAutomationSourceApplicationResolver.current(
      confidence: "manual-review-text-paste"
    )
    let result: AutomationPolicyExecutionResult
    do {
      let interval = DashboardReviewsTextPasteTrace.beginPolicyExecute(
        referenceCount: references.count
      )
      defer { DashboardReviewsTextPasteTrace.end(interval) }
      result = pastedTextPolicyResult(
        text: text,
        references: references,
        sourceApplication: sourceApplication,
        policyCenter: policyCenter
      )
    }
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
    let toastRunner = DashboardPolicyToastCommandRunner(
      toast: store.toast,
      policyID: result.policyDecision.policy.id
    )
    toastRunner.showInitial(result.toastCommands)
    defer {
      toastRunner.finish(result.toastCommands)
    }
    let resolution: DashboardReviewsPastedTextResolution
    do {
      let interval = DashboardReviewsTextPasteTrace.beginResolveReferences(
        referenceCount: result.reviewPullRequestReferences.count
      )
      defer { DashboardReviewsTextPasteTrace.end(interval) }
      resolution = await resolvePastedReviewReferences(
        result.reviewPullRequestReferences,
        configuration: result.policyDecision.policy.reviewPullRequestExtraction
          ?? ReviewPullRequestExtractionConfiguration(autoCopy: false)
      )
    }
    toastRunner.updateAfterResolution(result.toastCommands)
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

  func preparePastedReviewTextPolicyRuntime(
    policyCenter: AutomationPolicyCenter
  ) async {
    await store.ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies()
    synchronizeEnforcedCanvasAutomationPolicies(policyCenter: policyCenter)
  }

  func synchronizeEnforcedCanvasAutomationPolicies(
    policyCenter: AutomationPolicyCenter
  ) {
    DashboardAutomationPolicyRuntimeSynchronizer.synchronizeEnforcedCanvasAutomationPolicies(
      policyCenter: policyCenter,
      workspace: store.globalPolicyCanvasWorkspace,
      activeDocument: store.globalPolicyPipeline
    )
  }

  private func applyPastedTextPolicyResult(
    _ result: AutomationPolicyExecutionResult,
    text: String,
    references: [GitHubPullRequestReference],
    resolution: DashboardReviewsPastedTextResolution
  ) async {
    let actions = Set(result.executedActions)
    if actions.contains(.previewReviewApprovals) {
      let preview: ReviewsActionPreviewResponse
      do {
        let interval = DashboardReviewsTextPasteTrace.beginPreviewApproval(
          itemCount: resolution.items.count
        )
        defer { DashboardReviewsTextPasteTrace.end(interval) }
        preview = await reviewActionPreview(.approve, items: resolution.items)
      }
      routePastedTextReviewSheet = DashboardReviewsPastedTextReviewSheetState(
        policyName: result.policyName,
        textPreview: String(text.prefix(1_000)),
        references: references,
        items: resolution.items,
        missingReferences: resolution.missingReferences,
        extractionRows: resolution.extractionRows,
        outputText: resolution.outputText,
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
    _ references: [GitHubPullRequestReference],
    configuration: ReviewPullRequestExtractionConfiguration
  ) async -> DashboardReviewsPastedTextResolution {
    let rows = ReviewPullRequestExtractionService.rows(from: references)
    let result = await ReviewPullRequestExtractionService.resolve(
      rows: rows,
      context: ReviewPullRequestExtractionContext(
        currentItems: routeResponse.items,
        configuredRepositories: configuredReviewExtractionRepositories(configuration),
        activeReviewsRepository: primaryDetailItem?.repository,
        configuration: configuration,
        fetchPullRequests: { references in
          guard let client = store.apiClient else { return [] }
          return await fetchPastedReviewPullRequests(references, client: client)
        },
        fetchRepositories: { repositories in
          guard let client = store.apiClient else { return [] }
          return await fetchPastedReviewRepositories(repositories, client: client)
        }
      )
    )
    let missingReferences = result.rows.compactMap { row -> GitHubPullRequestReference? in
      guard row.status != .matched, case .resolved(let reference) = row.row.reference else {
        return nil
      }
      return reference
    }
    return DashboardReviewsPastedTextResolution(
      items: result.matchedItems,
      missingReferences: missingReferences,
      extractionRows: result.rows,
      outputText: result.outputText
    )
  }

  func fetchPastedReviewPullRequests(
    _ references: [ReviewsPullRequestReference],
    client: any HarnessMonitorClientProtocol
  ) async -> [ReviewItem] {
    let references = orderedUnique(references)
    guard !references.isEmpty else { return [] }
    let interval = DashboardReviewsTextPasteTrace.beginResolvePullRequests(
      referenceCount: references.count
    )
    defer { DashboardReviewsTextPasteTrace.end(interval) }
    do {
      let response = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.resolveReviewPullRequests(
          request: ReviewsPullRequestResolveRequest(
            references: references,
            backportDetectionEnabled: normalizedPreferences.backportDetectionEnabled,
            backportPatterns: normalizedPreferences.normalizedBackportPatterns
          )
        )
      }
      let normalized = HarnessMonitorReviewsDaemonNormalizer.normalize(
        refresh: ReviewsRefreshResponse(fetchedAt: response.fetchedAt, items: response.items),
        daemonWireVersion: store.health?.wireVersion
      )
      return normalized.items
    } catch {
      store.toast.presentWarning("Could not load pasted PRs: \(error.localizedDescription)")
      return []
    }
  }

  func fetchPastedReviewRepositories(
    _ repositories: [String],
    client: any HarnessMonitorClientProtocol
  ) async -> [ReviewItem] {
    let repositories = orderedUnique(repositories)
    guard !repositories.isEmpty else { return [] }
    let interval = DashboardReviewsTextPasteTrace.beginFetchRepositories(
      repositoryCount: repositories.count
    )
    defer { DashboardReviewsTextPasteTrace.end(interval) }
    do {
      let response = try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.queryReviews(
          request: ReviewsQueryRequest(
            repositories: repositories,
            forceRefresh: false,
            cacheMaxAgeSeconds: normalizedPreferences.cacheMaxAgeSeconds,
            backportDetectionEnabled: normalizedPreferences.backportDetectionEnabled,
            backportPatterns: normalizedPreferences.normalizedBackportPatterns
          )
        )
      }
      mergePastedReviewResponse(response, repositories: repositories)
      return HarnessMonitorReviewsDaemonNormalizer.normalize(
        response: response,
        daemonWireVersion: store.health?.wireVersion
      ).items
    } catch {
      store.toast.presentWarning("Could not refresh pasted PRs: \(error.localizedDescription)")
      return []
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

  private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0.lowercased()).inserted }
  }

  private func orderedUnique(
    _ values: [ReviewsPullRequestReference]
  ) -> [ReviewsPullRequestReference] {
    var seen = Set<String>()
    return values.filter { value in
      seen.insert("\(value.repository.lowercased())#\(value.number)").inserted
    }
  }

  func configuredReviewExtractionRepositories(
    _ configuration: ReviewPullRequestExtractionConfiguration
  ) -> [String] {
    let taskBoardInbox =
      store.globalTaskBoardOrchestratorStatus?.settings.githubInbox.repositories ?? []
    let configured = routeResolvedPreferences.repositories + taskBoardInbox
    switch configuration.repositoryMode {
    case .allConfiguredRepos:
      return orderedUnique(configured)
    case .policyRepositories:
      return orderedUnique(configuration.policyRepositories)
    case .activeReviewsRepository:
      return primaryDetailItem.map { [$0.repository] } ?? orderedUnique(configured)
    }
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
