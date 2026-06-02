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
private extension PolicyCanvasAutomationStoreState {
  static func bridgeState(_ center: AutomationPolicyCenter) -> Self {
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

private extension HarnessMonitorPolicyCanvas.ClipboardAutomationRuntimeState {
  init(_ state: ClipboardAutomationRuntimeState) {
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

private extension HarnessMonitorPolicyCanvas.AutomationPolicyEventSource {
  init(_ source: AutomationPolicyEventSource) {
    switch source {
    case .clipboard:
      self = .clipboard
    case .manualOCRPaste:
      self = .manualOCRPaste
    case .manualReviewTextPaste:
      self = .manualReviewTextPaste
    case .ocrDrop:
      self = .ocrDrop
    case .ocrFilePicker:
      self = .ocrFilePicker
    case .screenshotFolder:
      self = .screenshotFolder
    }
  }
}

private extension AutomationPolicyEventSource {
  init(_ source: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource) {
    switch source {
    case .clipboard:
      self = .clipboard
    case .manualOCRPaste:
      self = .manualOCRPaste
    case .manualReviewTextPaste:
      self = .manualReviewTextPaste
    case .ocrDrop:
      self = .ocrDrop
    case .ocrFilePicker:
      self = .ocrFilePicker
    case .screenshotFolder:
      self = .screenshotFolder
    }
  }
}

private extension HarnessMonitorPolicyCanvas.AutomationClipboardContentKind {
  init(_ kind: AutomationClipboardContentKind) {
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

private extension AutomationClipboardContentKind {
  init(_ kind: HarnessMonitorPolicyCanvas.AutomationClipboardContentKind) {
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

private extension HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor {
  init(_ preprocessor: AutomationPolicyPreprocessor) {
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

private extension AutomationPolicyPreprocessor {
  init(_ preprocessor: HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor) {
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

private extension HarnessMonitorPolicyCanvas.AutomationPolicyAction {
  init(_ action: AutomationPolicyAction) {
    switch action {
    case .ocrImage:
      self = .ocrImage
    case .extractGitHubPullRequests:
      self = .extractGitHubPullRequests
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

private extension AutomationPolicyAction {
  init(_ action: HarnessMonitorPolicyCanvas.AutomationPolicyAction) {
    switch action {
    case .ocrImage:
      self = .ocrImage
    case .extractGitHubPullRequests:
      self = .extractGitHubPullRequests
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

private extension HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor {
  init(_ postprocessor: AutomationPolicyPostprocessor) {
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

private extension AutomationPolicyPostprocessor {
  init(_ postprocessor: HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor) {
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

private extension HarnessMonitorPolicyCanvas.AutomationSourceAppMode {
  init(_ mode: AutomationSourceAppMode) {
    switch mode {
    case .allExceptDenied:
      self = .allExceptDenied
    case .allowedOnly:
      self = .allowedOnly
    }
  }
}

private extension AutomationSourceAppMode {
  init(_ mode: HarnessMonitorPolicyCanvas.AutomationSourceAppMode) {
    switch mode {
    case .allExceptDenied:
      self = .allExceptDenied
    case .allowedOnly:
      self = .allowedOnly
    }
  }
}

private extension HarnessMonitorPolicyCanvas.AutomationSourceApplication {
  init(_ sourceApplication: AutomationSourceApplication) {
    self.init(
      bundleIdentifier: sourceApplication.bundleIdentifier,
      localizedName: sourceApplication.localizedName,
      processIdentifier: sourceApplication.processIdentifier,
      confidence: sourceApplication.confidence
    )
  }
}

private extension HarnessMonitorPolicyCanvas.AutomationSourceAppFilter {
  init(_ filter: AutomationSourceAppFilter) {
    self.init(
      mode: HarnessMonitorPolicyCanvas.AutomationSourceAppMode(filter.mode),
      allowedBundleIdentifiers: filter.allowedBundleIdentifiers,
      deniedBundleIdentifiers: filter.deniedBundleIdentifiers
    )
  }
}

private extension HarnessMonitorPolicyCanvas.AutomationPolicyMatch {
  init(_ match: AutomationPolicyMatch) {
    self.init(
      contentKinds: Set(
        match.contentKinds.map(HarnessMonitorPolicyCanvas.AutomationClipboardContentKind.init)
      ),
      sourceAppFilter: HarnessMonitorPolicyCanvas.AutomationSourceAppFilter(match.sourceAppFilter)
    )
  }
}

private extension HarnessMonitorPolicyCanvas.AutomationPolicy {
  init(_ policy: AutomationPolicy) {
    self.init(
      id: policy.id,
      name: policy.name,
      eventSource: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource(policy.eventSource),
      isEnabled: policy.isEnabled,
      priority: policy.priority,
      match: HarnessMonitorPolicyCanvas.AutomationPolicyMatch(policy.match),
      preprocessors: policy.preprocessors.map(HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor.init),
      actions: policy.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      dryRun: policy.isDryRun,
      postprocessors: policy.postprocessors.map(HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor.init)
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
      postprocessors: policy.postprocessors.map(AutomationPolicyPostprocessor.init)
    )
  }
}

private extension AutomationPolicyMatch {
  init(_ match: HarnessMonitorPolicyCanvas.AutomationPolicyMatch) {
    self.init(
      contentKinds: Set(match.contentKinds.map(AutomationClipboardContentKind.init)),
      sourceAppFilter: AutomationSourceAppFilter(match.sourceAppFilter)
    )
  }
}

private extension AutomationSourceAppFilter {
  init(_ filter: HarnessMonitorPolicyCanvas.AutomationSourceAppFilter) {
    self.init(
      mode: AutomationSourceAppMode(filter.mode),
      allowedBundleIdentifiers: filter.allowedBundleIdentifiers,
      deniedBundleIdentifiers: filter.deniedBundleIdentifiers
    )
  }
}

private extension HarnessMonitorPolicyCanvas.AutomationPolicyDocument {
  init(_ document: AutomationPolicyDocument) {
    self.init(
      version: document.version,
      isEnabled: document.isEnabled,
      policies: document.policies.map(HarnessMonitorPolicyCanvas.AutomationPolicy.init),
      updatedAt: document.updatedAt
    )
  }
}

private extension HarnessMonitorPolicyCanvas.AutomationPolicyEventOutcome {
  init(_ outcome: AutomationPolicyEventOutcome) {
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

private extension HarnessMonitorPolicyCanvas.AutomationPolicyEventRecord {
  init(_ event: AutomationPolicyEventRecord) {
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
      sourceApplication: event.sourceApplication.map(HarnessMonitorPolicyCanvas.AutomationSourceApplication.init),
      actions: event.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      postprocessors: event.postprocessors.map(HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor.init),
      executedActions: event.executedActions?.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      skippedActions: event.skippedActions?.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
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
