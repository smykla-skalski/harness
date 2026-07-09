import HarnessMonitorPolicyCanvas

extension HarnessMonitorPolicyCanvas.AutomationPolicyExecutionStep {
  init(_ step: AutomationPolicyExecutionStep) {
    self.init(
      nodeID: step.nodeID,
      inputPayload: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind(step.inputPayload),
      outputPayload: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind(step.outputPayload),
      actions: step.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      toastCommand: step.toastCommand.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyToastCommand.init
      )
    )
  }
}

extension AutomationPolicyExecutionStep {
  init(_ step: HarnessMonitorPolicyCanvas.AutomationPolicyExecutionStep) {
    self.init(
      nodeID: step.nodeID,
      inputPayload: AutomationPolicyPayloadKind(step.inputPayload),
      outputPayload: AutomationPolicyPayloadKind(step.outputPayload),
      actions: step.actions.map(AutomationPolicyAction.init),
      toastCommand: step.toastCommand.map(AutomationPolicyToastCommand.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyFanOutBranch {
  init(_ branch: AutomationPolicyFanOutBranch) {
    self.init(
      outputPortID: branch.outputPortID,
      targetNodeID: branch.targetNodeID,
      actions: branch.actions.map(HarnessMonitorPolicyCanvas.AutomationPolicyAction.init),
      toastCommand: branch.toastCommand.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyToastCommand.init
      )
    )
  }
}

extension AutomationPolicyFanOutBranch {
  init(_ branch: HarnessMonitorPolicyCanvas.AutomationPolicyFanOutBranch) {
    self.init(
      outputPortID: branch.outputPortID,
      targetNodeID: branch.targetNodeID,
      actions: branch.actions.map(AutomationPolicyAction.init),
      toastCommand: branch.toastCommand.map(AutomationPolicyToastCommand.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyToastCommand {
  init(_ command: AutomationPolicyToastCommand) {
    self.init(
      key: command.key,
      kind: HarnessMonitorPolicyCanvas.AutomationPolicyToastCommandKind(command.kind),
      title: command.title,
      message: command.message,
      position: command.position
    )
  }
}

extension AutomationPolicyToastCommand {
  init(_ command: HarnessMonitorPolicyCanvas.AutomationPolicyToastCommand) {
    self.init(
      key: command.key,
      kind: AutomationPolicyToastCommandKind(command.kind),
      title: command.title,
      message: command.message,
      position: command.position
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyToastCommandKind {
  init(_ kind: AutomationPolicyToastCommandKind) {
    switch kind {
    case .show:
      self = .show
    case .update:
      self = .update
    case .hide:
      self = .hide
    }
  }
}

extension AutomationPolicyToastCommandKind {
  init(_ kind: HarnessMonitorPolicyCanvas.AutomationPolicyToastCommandKind) {
    switch kind {
    case .show:
      self = .show
    case .update:
      self = .update
    case .hide:
      self = .hide
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyFanOut {
  init(_ fanOut: AutomationPolicyFanOut) {
    self.init(
      hubNodeID: fanOut.hubNodeID,
      payload: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind(fanOut.payload),
      branches: fanOut.branches.map(HarnessMonitorPolicyCanvas.AutomationPolicyFanOutBranch.init)
    )
  }
}

extension AutomationPolicyFanOut {
  init(_ fanOut: HarnessMonitorPolicyCanvas.AutomationPolicyFanOut) {
    self.init(
      hubNodeID: fanOut.hubNodeID,
      payload: AutomationPolicyPayloadKind(fanOut.payload),
      branches: fanOut.branches.map(AutomationPolicyFanOutBranch.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyExecutionPlan {
  init(_ plan: AutomationPolicyExecutionPlan) {
    self.init(
      sourceNodeID: plan.sourceNodeID,
      eventSource: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource(plan.eventSource),
      steps: plan.steps.map(HarnessMonitorPolicyCanvas.AutomationPolicyExecutionStep.init),
      fanOuts: plan.fanOuts.map(HarnessMonitorPolicyCanvas.AutomationPolicyFanOut.init)
    )
  }
}

extension AutomationPolicyExecutionPlan {
  init(_ plan: HarnessMonitorPolicyCanvas.AutomationPolicyExecutionPlan) {
    self.init(
      sourceNodeID: plan.sourceNodeID,
      eventSource: AutomationPolicyEventSource(plan.eventSource),
      steps: plan.steps.map(AutomationPolicyExecutionStep.init),
      fanOuts: plan.fanOuts.map(AutomationPolicyFanOut.init)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationSourceAppMode {
  init(_ mode: AutomationSourceAppMode) {
    switch mode {
    case .allExceptDenied:
      self = .allExceptDenied
    case .allowedOnly:
      self = .allowedOnly
    }
  }
}

extension AutomationSourceAppMode {
  init(_ mode: HarnessMonitorPolicyCanvas.AutomationSourceAppMode) {
    switch mode {
    case .allExceptDenied:
      self = .allExceptDenied
    case .allowedOnly:
      self = .allowedOnly
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationSourceApplication {
  init(_ sourceApplication: AutomationSourceApplication) {
    self.init(
      bundleIdentifier: sourceApplication.bundleIdentifier,
      localizedName: sourceApplication.localizedName,
      processIdentifier: sourceApplication.processIdentifier,
      confidence: sourceApplication.confidence
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationSourceAppFilter {
  init(_ filter: AutomationSourceAppFilter) {
    self.init(
      mode: HarnessMonitorPolicyCanvas.AutomationSourceAppMode(filter.mode),
      allowedBundleIdentifiers: filter.allowedBundleIdentifiers,
      deniedBundleIdentifiers: filter.deniedBundleIdentifiers
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyMatch {
  init(_ match: AutomationPolicyMatch) {
    self.init(
      contentKinds: Set(
        match.contentKinds.map(HarnessMonitorPolicyCanvas.AutomationClipboardContentKind.init)
      ),
      sourceAppFilter: HarnessMonitorPolicyCanvas.AutomationSourceAppFilter(match.sourceAppFilter)
    )
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration.RecognitionLevel {
  init(_ level: AutomationPolicyOCRConfiguration.RecognitionLevel) {
    switch level {
    case .accurate:
      self = .accurate
    case .fast:
      self = .fast
    }
  }
}

extension AutomationPolicyOCRConfiguration.RecognitionLevel {
  init(
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
  init(_ configuration: AutomationPolicyOCRConfiguration) {
    self.init(
      recognitionLevel:
        Self.RecognitionLevel(
          configuration.recognitionLevel
        ),
      automaticallyDetectsLanguage: configuration.automaticallyDetectsLanguage,
      usesLanguageCorrection: configuration.usesLanguageCorrection
    )
  }
}

extension AutomationPolicyOCRConfiguration {
  init(_ configuration: HarnessMonitorPolicyCanvas.AutomationPolicyOCRConfiguration) {
    self.init(
      recognitionLevel: Self.RecognitionLevel(
        configuration.recognitionLevel
      ),
      automaticallyDetectsLanguage: configuration.automaticallyDetectsLanguage,
      usesLanguageCorrection: configuration.usesLanguageCorrection
    )
  }
}

extension HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration.RepositoryMode {
  init(_ mode: ReviewPullRequestExtractionConfiguration.RepositoryMode) {
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
  init(
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
  init(_ scope: ReviewPullRequestExtractionConfiguration.ResultScope) {
    switch scope {
    case .all:
      self = .all
    case .failing:
      self = .failing
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.ResultScope {
  init(
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
  init(_ mode: ReviewPullRequestExtractionConfiguration.FailureSignalMode) {
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
  init(
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
  init(_ format: ReviewPullRequestExtractionConfiguration.OutputFormat) {
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
  init(
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
  init(_ configuration: ReviewPullRequestExtractionConfiguration) {
    self.init(
      repositoryMode:
        Self.RepositoryMode(
          configuration.repositoryMode
        ),
      policyRepositories: configuration.policyRepositories,
      numberMemoryEnabled: configuration.numberMemoryEnabled,
      resultScope: Self.ResultScope(
        configuration.resultScope
      ),
      failureSignalMode:
        Self.FailureSignalMode(
          configuration.failureSignalMode
        ),
      outputFormat:
        Self
        .OutputFormat(
          configuration.outputFormat
        ),
      autoCopy: configuration.autoCopy,
      showSheet: configuration.showSheet
    )
  }
}

extension ReviewPullRequestExtractionConfiguration {
  init(
    _ configuration: HarnessMonitorPolicyCanvas.ReviewPullRequestExtractionConfiguration
  ) {
    self.init(
      repositoryMode: Self.RepositoryMode(
        configuration.repositoryMode
      ),
      policyRepositories: configuration.policyRepositories,
      numberMemoryEnabled: configuration.numberMemoryEnabled,
      resultScope: Self.ResultScope(
        configuration.resultScope
      ),
      failureSignalMode: Self.FailureSignalMode(
        configuration.failureSignalMode
      ),
      outputFormat: Self.OutputFormat(
        configuration.outputFormat
      ),
      autoCopy: configuration.autoCopy,
      showSheet: configuration.showSheet
    )
  }
}
