import HarnessMonitorPolicyCanvas

extension HarnessMonitorPolicyCanvas.AutomationPolicy {
  init(_ policy: AutomationPolicy) {
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
  init(_ match: HarnessMonitorPolicyCanvas.AutomationPolicyMatch) {
    self.init(
      contentKinds: Set(match.contentKinds.map(AutomationClipboardContentKind.init)),
      sourceAppFilter: AutomationSourceAppFilter(match.sourceAppFilter)
    )
  }
}

extension AutomationSourceAppFilter {
  init(_ filter: HarnessMonitorPolicyCanvas.AutomationSourceAppFilter) {
    self.init(
      mode: AutomationSourceAppMode(filter.mode),
      allowedBundleIdentifiers: filter.allowedBundleIdentifiers,
      deniedBundleIdentifiers: filter.deniedBundleIdentifiers
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyDocument {
  init(_ document: AutomationPolicyDocument) {
    self.init(
      version: document.version,
      isEnabled: document.isEnabled,
      policies: document.policies.map(HarnessMonitorPolicyCanvas.AutomationPolicy.init),
      updatedAt: document.updatedAt
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyEventOutcome {
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

extension HarnessMonitorPolicyCanvas.AutomationPolicyEventRecord {
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
