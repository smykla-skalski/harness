import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvas

extension DashboardReviewsTextPasteSheetHost {
  func handlePastedReviewText(_ text: String) async {
    let handleInterval = DashboardReviewsTextPasteTrace.beginHandle(textLength: text.count)
    defer { DashboardReviewsTextPasteTrace.end(handleInterval) }
    let policyCenter = AutomationPolicyCenter.shared
    do {
      let interval = DashboardReviewsTextPasteTrace.beginPreparePolicyRuntime()
      defer { DashboardReviewsTextPasteTrace.end(interval) }
      await preparePastedReviewTextPolicyRuntime(policyCenter: policyCenter)
    }
    guard !Task.isCancelled else { return }
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
    let configuration =
      result.policyDecision.policy.reviewPullRequestExtraction
      ?? ReviewPullRequestExtractionConfiguration(autoCopy: false)
    let resolution: DashboardReviewsPastedTextResolution
    do {
      let interval = DashboardReviewsTextPasteTrace.beginResolveReferences(
        referenceCount: result.reviewPullRequestReferences.count
      )
      defer { DashboardReviewsTextPasteTrace.end(interval) }
      resolution = await resolvePastedReviewReferences(
        result.reviewPullRequestReferences,
        configuration: configuration
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

  private func preparePastedReviewTextPolicyRuntime(
    policyCenter: AutomationPolicyCenter
  ) async {
    await store.ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies()
    DashboardAutomationPolicyRuntimeSynchronizer.synchronizeEnforcedCanvasAutomationPolicies(
      policyCenter: policyCenter,
      workspace: store.globalPolicyCanvasWorkspace,
      activeDocument: store.globalPolicyPipeline
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
        summary: pastedTextSummary(
          references: references,
          sourceApplication: sourceApplication
        ),
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

  private func applyPastedTextPolicyResult(
    _ result: AutomationPolicyExecutionResult,
    text: String,
    references: [GitHubPullRequestReference],
    resolution: DashboardReviewsPastedTextResolution
  ) async {
    let actions = Set(result.executedActions)
    if actions.contains(.previewReviewApprovals) {
      await presentPastedTextReviewSheet(
        result,
        text: text,
        references: references,
        resolution: resolution,
        offersAutoPolicy: actions.contains(.runReviewPolicy)
      )
      return
    }
    if actions.contains(.promptReviewApprovals) {
      await presentPastedTextReviewSheet(
        result,
        text: text,
        references: references,
        resolution: resolution,
        offersAutoPolicy: false
      )
      return
    }
    if actions.contains(.runReviewPolicy) {
      autoPastedTextReviewItems(resolution.items)
      return
    }
    if actions.contains(.approveReviewPullRequests) {
      enqueuePastedReviewApproval(
        items: resolution.items,
        dryRun: result.shouldDryRunReviewApprovals
      )
      return
    }
    store.toast.presentSuccess("Loaded \(resolution.items.count) pasted pull request(s)")
  }

  private func presentPastedTextReviewSheet(
    _ result: AutomationPolicyExecutionResult,
    text: String,
    references: [GitHubPullRequestReference],
    resolution: DashboardReviewsPastedTextResolution,
    offersAutoPolicy: Bool
  ) async {
    let preview: ReviewsActionPreviewResponse
    do {
      let interval = DashboardReviewsTextPasteTrace.beginPreviewApproval(
        itemCount: resolution.items.count
      )
      defer { DashboardReviewsTextPasteTrace.end(interval) }
      preview = await reviewActionPreview(.approve, items: resolution.items)
    }
    guard !Task.isCancelled else { return }
    presentPastedTextReviewSheet(
      DashboardReviewsPastedTextReviewSheetState(
        policyName: result.policyName,
        textPreview: String(text.prefix(1_000)),
        references: references,
        items: resolution.items,
        missingReferences: resolution.missingReferences,
        extractionRows: resolution.extractionRows,
        outputText: resolution.outputText,
        approvalPreview: preview,
        offersAutoPolicy: offersAutoPolicy,
        dryRun: result.shouldDryRunReviewApprovals
      )
    )
  }

  private func resolvePastedReviewReferences(
    _ references: [GitHubPullRequestReference],
    configuration: ReviewPullRequestExtractionConfiguration
  ) async -> DashboardReviewsPastedTextResolution {
    let rows = ReviewPullRequestExtractionService.rows(from: references)
    let resolvedPreferences = DashboardReviewsResolvedPreferences(storedValue: storedPreferences)
    let result = await ReviewPullRequestExtractionService.resolve(
      rows: rows,
      context: ReviewPullRequestExtractionContext(
        currentItems: openAnythingReviews.loadedItems,
        configuredRepositories: configuredReviewExtractionRepositories(
          configuration,
          preferences: resolvedPreferences
        ),
        activeReviewsRepository: nil,
        configuration: configuration,
        fetchRepositories: { repositories in
          guard let client = store.apiClient else { return [] }
          return await fetchPastedReviewRepositories(
            repositories,
            preferences: resolvedPreferences.preferences,
            client: client
          )
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

  private func configuredReviewExtractionRepositories(
    _ configuration: ReviewPullRequestExtractionConfiguration,
    preferences: DashboardReviewsResolvedPreferences
  ) -> [String] {
    let taskBoardInbox =
      store.globalTaskBoardOrchestratorStatus?.settings.githubInbox.repositories ?? []
    let configured = preferences.repositories + taskBoardInbox
    switch configuration.repositoryMode {
    case .allConfiguredRepos:
      return orderedUnique(configured)
    case .policyRepositories:
      return orderedUnique(configuration.policyRepositories)
    case .activeReviewsRepository:
      return orderedUnique(configured)
    }
  }

  private func fetchPastedReviewRepositories(
    _ repositories: [String],
    preferences: DashboardReviewsPreferences,
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
            cacheMaxAgeSeconds: max(
              preferences.cacheMaxAgeSeconds,
              DashboardReviewsPreferences.minimumPerRepositoryIntervalSeconds
            ),
            backportDetectionEnabled: preferences.backportDetectionEnabled,
            backportPatterns: preferences.normalizedBackportPatterns
          )
        )
      }
      return HarnessMonitorReviewsDaemonNormalizer.normalize(
        response: response,
        daemonWireVersion: store.health?.wireVersion
      ).items
    } catch {
      store.toast.presentWarning("Could not refresh pasted PRs: \(error.localizedDescription)")
      return []
    }
  }

  private func reviewActionPreview(
    _ action: DashboardReviewAttentionActionKind,
    items: [ReviewItem]
  ) async -> ReviewsActionPreviewResponse {
    let preferences = DashboardReviewsResolvedPreferences(storedValue: storedPreferences)
      .preferences
    let request = ReviewsActionPreviewRequest(
      action: action.previewKind,
      targets: items.map(\.target),
      method: preferences.mergeMethod
    )
    guard let client = store.apiClient else {
      return localReviewActionPreview(action.previewKind, items: items)
    }
    do {
      return try await DashboardReviewsTimeoutRacer.race(
        timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
      ) {
        try await client.previewReviewAction(request: request)
      }
    } catch {
      HarnessMonitorLogger.api.warning(
        "Review action preview failed: \(String(reflecting: error), privacy: .public)"
      )
      return localReviewActionPreview(action.previewKind, items: items)
    }
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
