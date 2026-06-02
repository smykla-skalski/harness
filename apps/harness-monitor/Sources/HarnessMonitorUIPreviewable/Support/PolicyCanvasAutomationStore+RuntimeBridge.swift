import HarnessMonitorPolicyCanvas

@MainActor
extension PolicyCanvasAutomationStore {
  static func automationCenterBridge(
    center: AutomationPolicyCenter = .shared
  ) -> PolicyCanvasAutomationStore {
    PolicyCanvasAutomationStore(
      state: .bridgeState(center),
      setAutomationEnabled: { isEnabled in
        center.setAutomationEnabled(isEnabled)
        return .bridgeState(center)
      },
      replaceCanvasPolicies: { policies in
        center.replaceCanvasPolicies(policies.map(AutomationPolicy.init))
        return .bridgeState(center)
      }
    )
  }
}

@MainActor
extension PolicyCanvasAutomationStoreState {
  fileprivate static func bridgeState(_ center: AutomationPolicyCenter) -> Self {
    PolicyCanvasAutomationStoreState(
      document: HarnessMonitorPolicyCanvas.AutomationPolicyDocument(center.document),
      clipboardRuntimeState: HarnessMonitorPolicyCanvas.ClipboardAutomationRuntimeState(
        center.clipboardRuntimeState
      ),
      lastClipboardEventSummary: center.lastClipboardEventSummary,
      lastClipboardEventAt: center.lastClipboardEventAt,
      recentAutomationEvents: center.recentAutomationEvents.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyEventRecord.init
      )
    )
  }
}

extension HarnessMonitorPolicyCanvas.ClipboardAutomationRuntimeState {
  fileprivate init(_ state: ClipboardAutomationRuntimeState) {
    switch state {
    case .off:
      self = .off
    case .watching:
      self = .watching
    case .paused(let reason):
      self = .paused(reason)
    case .denied:
      self = .denied
    case .skipped(let reason):
      self = .skipped(reason)
    case .matched(let policy):
      self = .matched(policy)
    case .failed(let message):
      self = .failed(message)
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyEventSource {
  fileprivate init(_ source: AutomationPolicyEventSource) {
    switch source {
    case .clipboard:
      self = .clipboard
    case .manualOCRPaste:
      self = .manualOCRPaste
    case .manualReviewTextPaste:
      self = .manualReviewTextPaste
    case .reviewScreenshotPaste:
      self = .reviewScreenshotPaste
    case .ocrDrop:
      self = .ocrDrop
    case .ocrFilePicker:
      self = .ocrFilePicker
    case .screenshotFolder:
      self = .screenshotFolder
    }
  }
}

extension AutomationPolicyEventSource {
  fileprivate init(_ source: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource) {
    switch source {
    case .clipboard:
      self = .clipboard
    case .manualOCRPaste:
      self = .manualOCRPaste
    case .manualReviewTextPaste:
      self = .manualReviewTextPaste
    case .reviewScreenshotPaste:
      self = .reviewScreenshotPaste
    case .ocrDrop:
      self = .ocrDrop
    case .ocrFilePicker:
      self = .ocrFilePicker
    case .screenshotFolder:
      self = .screenshotFolder
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationClipboardContentKind {
  fileprivate init(_ kind: AutomationClipboardContentKind) {
    switch kind {
    case .image:
      self = .image
    case .text:
      self = .text
    case .file:
      self = .file
    case .url:
      self = .url
    case .unknown:
      self = .unknown
    }
  }
}

extension AutomationClipboardContentKind {
  fileprivate init(_ kind: HarnessMonitorPolicyCanvas.AutomationClipboardContentKind) {
    switch kind {
    case .image:
      self = .image
    case .text:
      self = .text
    case .file:
      self = .file
    case .url:
      self = .url
    case .unknown:
      self = .unknown
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor {
  fileprivate init(_ preprocessor: AutomationPolicyPreprocessor) {
    switch preprocessor {
    case .respectPasteboardPrivacy:
      self = .respectPasteboardPrivacy
    case .skipSensitiveMarkers:
      self = .skipSensitiveMarkers
    case .filterSourceApplications:
      self = .filterSourceApplications
    case .dedupeByFingerprint:
      self = .dedupeByFingerprint
    case .normalizeGitHubPullRequestLinks:
      self = .normalizeGitHubPullRequestLinks
    case .dedupePullRequests:
      self = .dedupePullRequests
    }
  }
}

extension AutomationPolicyPreprocessor {
  fileprivate init(_ preprocessor: HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor) {
    switch preprocessor {
    case .respectPasteboardPrivacy:
      self = .respectPasteboardPrivacy
    case .skipSensitiveMarkers:
      self = .skipSensitiveMarkers
    case .filterSourceApplications:
      self = .filterSourceApplications
    case .dedupeByFingerprint:
      self = .dedupeByFingerprint
    case .normalizeGitHubPullRequestLinks:
      self = .normalizeGitHubPullRequestLinks
    case .dedupePullRequests:
      self = .dedupePullRequests
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyAction {
  fileprivate init(_ action: AutomationPolicyAction) {
    switch action {
    case .ocrImage:
      self = .ocrImage
    case .extractGitHubPullRequests:
      self = .extractGitHubPullRequests
    case .resolveReviewPullRequests:
      self = .resolveReviewPullRequests
    case .copyReviewPullRequestList:
      self = .copyReviewPullRequestList
    case .previewReviewApprovals:
      self = .previewReviewApprovals
    case .promptReviewApprovals:
      self = .promptReviewApprovals
    case .approveReviewPullRequests:
      self = .approveReviewPullRequests
    case .runReviewPolicy:
      self = .runReviewPolicy
    case .rememberRecentScan:
      self = .rememberRecentScan
    case .showFeedback:
      self = .showFeedback
    case .openDashboardDebugging:
      self = .openDashboardDebugging
    case .recordMetadata:
      self = .recordMetadata
    }
  }
}

extension AutomationPolicyAction {
  fileprivate init(_ action: HarnessMonitorPolicyCanvas.AutomationPolicyAction) {
    switch action {
    case .ocrImage:
      self = .ocrImage
    case .extractGitHubPullRequests:
      self = .extractGitHubPullRequests
    case .resolveReviewPullRequests:
      self = .resolveReviewPullRequests
    case .copyReviewPullRequestList:
      self = .copyReviewPullRequestList
    case .previewReviewApprovals:
      self = .previewReviewApprovals
    case .promptReviewApprovals:
      self = .promptReviewApprovals
    case .approveReviewPullRequests:
      self = .approveReviewPullRequests
    case .runReviewPolicy:
      self = .runReviewPolicy
    case .rememberRecentScan:
      self = .rememberRecentScan
    case .showFeedback:
      self = .showFeedback
    case .openDashboardDebugging:
      self = .openDashboardDebugging
    case .recordMetadata:
      self = .recordMetadata
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor {
  fileprivate init(_ postprocessor: AutomationPolicyPostprocessor) {
    switch postprocessor {
    case .sourceSpecificTextCleanup:
      self = .sourceSpecificTextCleanup
    case .persistResult:
      self = .persistResult
    case .auditEvent:
      self = .auditEvent
    }
  }
}

extension AutomationPolicyPostprocessor {
  fileprivate init(_ postprocessor: HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor) {
    switch postprocessor {
    case .sourceSpecificTextCleanup:
      self = .sourceSpecificTextCleanup
    case .persistResult:
      self = .persistResult
    case .auditEvent:
      self = .auditEvent
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind {
  fileprivate init(_ kind: AutomationPolicyPayloadKind) {
    switch kind {
    case .event:
      self = .event
    case .image:
      self = .image
    case .text:
      self = .text
    case .pullRequests:
      self = .pullRequests
    case .unknown:
      self = .unknown
    }
  }
}

extension AutomationPolicyPayloadKind {
  fileprivate init(_ kind: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind) {
    switch kind {
    case .event:
      self = .event
    case .image:
      self = .image
    case .text:
      self = .text
    case .pullRequests:
      self = .pullRequests
    case .unknown:
      self = .unknown
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyExecutionStep {
  fileprivate init(_ step: AutomationPolicyExecutionStep) {
    self.init(
      nodeID: step.nodeID,
      inputPayload: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind(step.inputPayload),
      outputPayload: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind(step.outputPayload),
      actions: step.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init)
    )
  }
}

extension AutomationPolicyExecutionStep {
  fileprivate init(_ step: HarnessMonitorPolicyCanvas.AutomationPolicyExecutionStep) {
    self.init(
      nodeID: step.nodeID,
      inputPayload: AutomationPolicyPayloadKind(step.inputPayload),
      outputPayload: AutomationPolicyPayloadKind(step.outputPayload),
      actions: step.actions.map(AutomationPolicyAction.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyFanOutBranch {
  fileprivate init(_ branch: AutomationPolicyFanOutBranch) {
    self.init(
      outputPortID: branch.outputPortID,
      targetNodeID: branch.targetNodeID,
      actions: branch.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init)
    )
  }
}

extension AutomationPolicyFanOutBranch {
  fileprivate init(_ branch: HarnessMonitorPolicyCanvas.AutomationPolicyFanOutBranch) {
    self.init(
      outputPortID: branch.outputPortID,
      targetNodeID: branch.targetNodeID,
      actions: branch.actions.map(AutomationPolicyAction.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyFanOut {
  fileprivate init(_ fanOut: AutomationPolicyFanOut) {
    self.init(
      hubNodeID: fanOut.hubNodeID,
      payload: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind(fanOut.payload),
      branches: fanOut.branches.map(HarnessMonitorPolicyCanvas.AutomationPolicyFanOutBranch.init)
    )
  }
}

extension AutomationPolicyFanOut {
  fileprivate init(_ fanOut: HarnessMonitorPolicyCanvas.AutomationPolicyFanOut) {
    self.init(
      hubNodeID: fanOut.hubNodeID,
      payload: AutomationPolicyPayloadKind(fanOut.payload),
      branches: fanOut.branches.map(AutomationPolicyFanOutBranch.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyExecutionPlan {
  fileprivate init(_ plan: AutomationPolicyExecutionPlan) {
    self.init(
      sourceNodeID: plan.sourceNodeID,
      eventSource: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource(plan.eventSource),
      steps: plan.steps.map(HarnessMonitorPolicyCanvas.AutomationPolicyExecutionStep.init),
      fanOuts: plan.fanOuts.map(HarnessMonitorPolicyCanvas.AutomationPolicyFanOut.init)
    )
  }
}

extension AutomationPolicyExecutionPlan {
  fileprivate init(_ plan: HarnessMonitorPolicyCanvas.AutomationPolicyExecutionPlan) {
    self.init(
      sourceNodeID: plan.sourceNodeID,
      eventSource: AutomationPolicyEventSource(plan.eventSource),
      steps: plan.steps.map(AutomationPolicyExecutionStep.init),
      fanOuts: plan.fanOuts.map(AutomationPolicyFanOut.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationSourceAppMode {
  fileprivate init(_ mode: AutomationSourceAppMode) {
    switch mode {
    case .allExceptDenied:
      self = .allExceptDenied
    case .allowedOnly:
      self = .allowedOnly
    }
  }
}

extension AutomationSourceAppMode {
  fileprivate init(_ mode: HarnessMonitorPolicyCanvas.AutomationSourceAppMode) {
    switch mode {
    case .allExceptDenied:
      self = .allExceptDenied
    case .allowedOnly:
      self = .allowedOnly
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationSourceApplication {
  fileprivate init(_ sourceApplication: AutomationSourceApplication) {
    self.init(
      bundleIdentifier: sourceApplication.bundleIdentifier,
      localizedName: sourceApplication.localizedName,
      processIdentifier: sourceApplication.processIdentifier,
      confidence: sourceApplication.confidence
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationSourceAppFilter {
  fileprivate init(_ filter: AutomationSourceAppFilter) {
    self.init(
      mode: HarnessMonitorPolicyCanvas.AutomationSourceAppMode(filter.mode),
      allowedBundleIdentifiers: filter.allowedBundleIdentifiers,
      deniedBundleIdentifiers: filter.deniedBundleIdentifiers
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyMatch {
  fileprivate init(_ match: AutomationPolicyMatch) {
    self.init(
      contentKinds: Set(
        match.contentKinds.map(HarnessMonitorPolicyCanvas.AutomationClipboardContentKind.init)
      ),
      sourceAppFilter: HarnessMonitorPolicyCanvas.AutomationSourceAppFilter(match.sourceAppFilter)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration.RecognitionLevel {
  fileprivate init(_ level: AutomationPolicyOCRConfiguration.RecognitionLevel) {
    switch level {
    case .accurate:
      self = .accurate
    case .fast:
      self = .fast
    }
  }
}

extension AutomationPolicyOCRConfiguration.RecognitionLevel {
  fileprivate init(
    _ level: HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration.RecognitionLevel
  ) {
    switch level {
    case .accurate:
      self = .accurate
    case .fast:
      self = .fast
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration {
  fileprivate init(_ configuration: AutomationPolicyOCRConfiguration) {
    self.init(
      recognitionLevel:
        HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration.RecognitionLevel(
          configuration.recognitionLevel
        ),
      automaticallyDetectsLanguage: configuration.automaticallyDetectsLanguage,
      usesLanguageCorrection: configuration.usesLanguageCorrection
    )
  }
}

extension AutomationPolicyOCRConfiguration {
  fileprivate init(_ configuration: HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration) {
    self.init(
      recognitionLevel: AutomationPolicyOCRConfiguration.RecognitionLevel(
        configuration.recognitionLevel
      ),
      automaticallyDetectsLanguage: configuration.automaticallyDetectsLanguage,
      usesLanguageCorrection: configuration.usesLanguageCorrection
    )
  }
}

extension HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.RepositoryMode {
  fileprivate init(_ mode: ReviewPullRequestExtractionConfiguration.RepositoryMode) {
    switch mode {
    case .allConfiguredRepos:
      self = .allConfiguredRepos
    case .policyRepositories:
      self = .policyRepositories
    case .activeReviewsRepository:
      self = .activeReviewsRepository
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.RepositoryMode {
  fileprivate init(
    _ mode: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.RepositoryMode
  ) {
    switch mode {
    case .allConfiguredRepos:
      self = .allConfiguredRepos
    case .policyRepositories:
      self = .policyRepositories
    case .activeReviewsRepository:
      self = .activeReviewsRepository
    }
  }
}

extension HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.ResultScope {
  fileprivate init(_ scope: ReviewPullRequestExtractionConfiguration.ResultScope) {
    switch scope {
    case .all:
      self = .all
    case .failing:
      self = .failing
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.ResultScope {
  fileprivate init(
    _ scope: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.ResultScope
  ) {
    switch scope {
    case .all:
      self = .all
    case .failing:
      self = .failing
    }
  }
}

extension HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration
  .FailureSignalMode
{
  fileprivate init(_ mode: ReviewPullRequestExtractionConfiguration.FailureSignalMode) {
    switch mode {
    case .liveReviews:
      self = .liveReviews
    case .visualScreenshot:
      self = .visualScreenshot
    case .liveOrVisual:
      self = .liveOrVisual
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.FailureSignalMode {
  fileprivate init(
    _ mode: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.FailureSignalMode
  ) {
    switch mode {
    case .liveReviews:
      self = .liveReviews
    case .visualScreenshot:
      self = .visualScreenshot
    case .liveOrVisual:
      self = .liveOrVisual
    }
  }
}

extension HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.OutputFormat {
  fileprivate init(_ format: ReviewPullRequestExtractionConfiguration.OutputFormat) {
    switch format {
    case .newlineGitHubURLs:
      self = .newlineGitHubURLs
    case .ownerRepoNumber:
      self = .ownerRepoNumber
    case .markdownLinks:
      self = .markdownLinks
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.OutputFormat {
  fileprivate init(
    _ format: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.OutputFormat
  ) {
    switch format {
    case .newlineGitHubURLs:
      self = .newlineGitHubURLs
    case .ownerRepoNumber:
      self = .ownerRepoNumber
    case .markdownLinks:
      self = .markdownLinks
    }
  }
}

extension HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration {
  fileprivate init(_ configuration: ReviewPullRequestExtractionConfiguration) {
    self.init(
      repositoryMode:
        HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.RepositoryMode(
          configuration.repositoryMode
        ),
      policyRepositories: configuration.policyRepositories,
      numberMemoryEnabled: configuration.numberMemoryEnabled,
      resultScope: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.ResultScope(
        configuration.resultScope
      ),
      failureSignalMode:
        HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.FailureSignalMode(
          configuration.failureSignalMode
        ),
      outputFormat: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration
        .OutputFormat(
          configuration.outputFormat
        ),
      autoCopy: configuration.autoCopy,
      showSheet: configuration.showSheet
    )
  }
}

extension ReviewPullRequestExtractionConfiguration {
  fileprivate init(
    _ configuration: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration
  ) {
    self.init(
      repositoryMode: ReviewPullRequestExtractionConfiguration.RepositoryMode(
        configuration.repositoryMode
      ),
      policyRepositories: configuration.policyRepositories,
      numberMemoryEnabled: configuration.numberMemoryEnabled,
      resultScope: ReviewPullRequestExtractionConfiguration.ResultScope(
        configuration.resultScope
      ),
      failureSignalMode: ReviewPullRequestExtractionConfiguration.FailureSignalMode(
        configuration.failureSignalMode
      ),
      outputFormat: ReviewPullRequestExtractionConfiguration.OutputFormat(
        configuration.outputFormat
      ),
      autoCopy: configuration.autoCopy,
      showSheet: configuration.showSheet
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicy {
  fileprivate init(_ policy: AutomationPolicy) {
    self.init(
      id: policy.id,
      name: policy.name,
      eventSource: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource(policy.eventSource),
      isEnabled: policy.isEnabled,
      priority: policy.priority,
      match: HarnessMonitorPolicyCanvas.AutomationPolicyMatch(policy.match),
      preprocessors: policy.preprocessors.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor.init),
      actions: policy.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      dryRun: policy.isDryRun,
      postprocessors: policy.postprocessors.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor.init),
      ocrConfiguration: policy.ocrConfiguration.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration.init
      ),
      reviewPullRequestExtraction: policy.reviewPullRequestExtraction.map(
        HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.init
      ),
      executionPlan: policy.executionPlan.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyExecutionPlan.init
      )
    )
  }
}

extension AutomationPolicy {
  init(_ policy: HarnessMonitorPolicyCanvas.AutomationPolicy) {
    self.init(
      id: policy.id,
      name: policy.name,
      eventSource: AutomationPolicyEventSource(policy.eventSource),
      isEnabled: policy.isEnabled,
      priority: policy.priority,
      match: AutomationPolicyMatch(policy.match),
      preprocessors: policy.preprocessors.map(AutomationPolicyPreprocessor.init),
      actions: policy.actions.map(AutomationPolicyAction.init),
      dryRun: policy.isDryRun,
      postprocessors: policy.postprocessors.map(AutomationPolicyPostprocessor.init),
      ocrConfiguration: policy.ocrConfiguration.map(AutomationPolicyOCRConfiguration.init),
      reviewPullRequestExtraction: policy.reviewPullRequestExtraction.map(
        ReviewPullRequestExtractionConfiguration.init
      ),
      executionPlan: policy.executionPlan.map(AutomationPolicyExecutionPlan.init)
    )
  }
}

extension AutomationPolicyMatch {
  fileprivate init(_ match: HarnessMonitorPolicyCanvas.AutomationPolicyMatch) {
    self.init(
      contentKinds: Set(match.contentKinds.map(AutomationClipboardContentKind.init)),
      sourceAppFilter: AutomationSourceAppFilter(match.sourceAppFilter)
    )
  }
}

extension AutomationSourceAppFilter {
  fileprivate init(_ filter: HarnessMonitorPolicyCanvas.AutomationSourceAppFilter) {
    self.init(
      mode: AutomationSourceAppMode(filter.mode),
      allowedBundleIdentifiers: filter.allowedBundleIdentifiers,
      deniedBundleIdentifiers: filter.deniedBundleIdentifiers
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyDocument {
  fileprivate init(_ document: AutomationPolicyDocument) {
    self.init(
      version: document.version,
      isEnabled: document.isEnabled,
      policies: document.policies.map(HarnessMonitorPolicyCanvas.AutomationPolicy.init),
      updatedAt: document.updatedAt
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyEventOutcome {
  fileprivate init(_ outcome: AutomationPolicyEventOutcome) {
    switch outcome {
    case .matched:
      self = .matched
    case .skipped:
      self = .skipped
    case .denied:
      self = .denied
    case .failed:
      self = .failed
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyEventRecord {
  fileprivate init(_ event: AutomationPolicyEventRecord) {
    self.init(
      id: event.id,
      occurredAt: event.occurredAt,
      source: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource(event.source),
      outcome: HarnessMonitorPolicyCanvas.AutomationPolicyEventOutcome(event.outcome),
      policyID: event.policyID,
      policyName: event.policyName,
      reason: event.reason,
      summary: event.summary,
      contentKinds: Set(
        event.contentKinds.map(HarnessMonitorPolicyCanvas.AutomationClipboardContentKind.init)
      ),
      declaredTypes: event.declaredTypes,
      detectedContentType: event.detectedContentType,
      sourceApplication: event.sourceApplication.map(
        HarnessMonitorPolicyCanvas.AutomationSourceApplication.init),
      actions: event.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      postprocessors: event.postprocessors.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor.init),
      executedActions: event.executedActions?.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      skippedActions: event.skippedActions?.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      executedPostprocessors: event.executedPostprocessors?.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor.init
      ),
      trigger: event.trigger,
      textPreview: event.textPreview,
      filePaths: event.filePaths,
      reviewPullRequests: event.reviewPullRequests
    )
  }
}
