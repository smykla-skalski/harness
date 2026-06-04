import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

extension TaskBoardPolicyPipelineAutomationBinding {
  static func canvasDefault(
    source: AutomationPolicyEventSource = .clipboard
  ) -> TaskBoardPolicyPipelineAutomationBinding {
    if source == .reviewScreenshotPaste {
      return TaskBoardPolicyPipelineAutomationBinding(
        isEnabled: true,
        eventSource: source.rawValue,
        priority: nil,
        contentKinds: [AutomationClipboardContentKind.image.rawValue],
        preprocessors: defaultPreprocessors(for: source).map(\.rawValue),
        actions: [
          AutomationPolicyAction.ocrImage.rawValue,
          AutomationPolicyAction.extractGitHubPullRequests.rawValue,
          AutomationPolicyAction.resolveReviewPullRequests.rawValue,
          AutomationPolicyAction.copyReviewPullRequestList.rawValue,
          AutomationPolicyAction.previewReviewApprovals.rawValue,
          AutomationPolicyAction.recordMetadata.rawValue,
        ],
        postprocessors: [AutomationPolicyPostprocessor.auditEvent.rawValue],
        sourceAppMode: AutomationSourceAppMode.allExceptDenied.rawValue,
        ocrConfiguration: TaskBoardPolicyPipelineOCRConfiguration(),
        reviewPullRequestExtraction: TaskBoardPolicyPipelineReviewPullRequestExtraction()
      )
    }
    if source == .manualReviewTextPaste {
      return TaskBoardPolicyPipelineAutomationBinding(
        isEnabled: true,
        eventSource: source.rawValue,
        priority: nil,
        contentKinds: [
          AutomationClipboardContentKind.text.rawValue,
          AutomationClipboardContentKind.url.rawValue,
        ],
        preprocessors: defaultPreprocessors(for: source).map(\.rawValue),
        actions: [
          AutomationPolicyAction.extractGitHubPullRequests.rawValue,
          AutomationPolicyAction.previewReviewApprovals.rawValue,
          AutomationPolicyAction.promptReviewApprovals.rawValue,
          AutomationPolicyAction.recordMetadata.rawValue,
        ],
        postprocessors: [AutomationPolicyPostprocessor.auditEvent.rawValue],
        sourceAppMode: AutomationSourceAppMode.allExceptDenied.rawValue
      )
    }
    return TaskBoardPolicyPipelineAutomationBinding(
      isEnabled: true,
      eventSource: source.rawValue,
      priority: nil,
      contentKinds: [AutomationClipboardContentKind.image.rawValue],
      preprocessors: defaultPreprocessors(for: source).map(\.rawValue),
      actions: [
        AutomationPolicyAction.ocrImage.rawValue,
        AutomationPolicyAction.rememberRecentScan.rawValue,
        AutomationPolicyAction.showFeedback.rawValue,
        AutomationPolicyAction.recordMetadata.rawValue,
      ],
      postprocessors: [
        AutomationPolicyPostprocessor.sourceSpecificTextCleanup.rawValue,
        AutomationPolicyPostprocessor.persistResult.rawValue,
        AutomationPolicyPostprocessor.auditEvent.rawValue,
      ],
      sourceAppMode: AutomationSourceAppMode.allExceptDenied.rawValue
    )
  }

  static func canvasComponent(
    contentKinds: [AutomationClipboardContentKind] = [],
    preprocessors: [AutomationPolicyPreprocessor] = [],
    actions: [AutomationPolicyAction] = [],
    postprocessors: [AutomationPolicyPostprocessor] = [],
    sourceAppMode: AutomationSourceAppMode = .allExceptDenied,
    allowedBundleIdentifiers: [String] = [],
    deniedBundleIdentifiers: [String] = []
  ) -> TaskBoardPolicyPipelineAutomationBinding {
    TaskBoardPolicyPipelineAutomationBinding(
      isEnabled: true,
      eventSource: AutomationPolicyEventSource.clipboard.rawValue,
      contentKinds: contentKinds.map(\.rawValue),
      preprocessors: preprocessors.map(\.rawValue),
      actions: actions.map(\.rawValue),
      postprocessors: postprocessors.map(\.rawValue),
      sourceAppMode: sourceAppMode.rawValue,
      allowedBundleIdentifiers: allowedBundleIdentifiers,
      deniedBundleIdentifiers: deniedBundleIdentifiers
    )
  }

  var resolvedEventSource: AutomationPolicyEventSource {
    AutomationPolicyEventSource(rawValue: eventSource) ?? .clipboard
  }

  var selectedContentKinds: Set<AutomationClipboardContentKind> {
    Set(contentKinds.compactMap(AutomationClipboardContentKind.init(rawValue:)))
  }

  var resolvedContentKinds: Set<AutomationClipboardContentKind> {
    selectedContentKinds.isEmpty ? [.image] : selectedContentKinds
  }

  var selectedPreprocessors: [AutomationPolicyPreprocessor] {
    selectedOrderedValues(AutomationPolicyPreprocessor.allCases, selectedRawValues: preprocessors)
  }

  var resolvedPreprocessors: [AutomationPolicyPreprocessor] {
    orderedValues(
      AutomationPolicyPreprocessor.allCases,
      selectedRawValues: preprocessors,
      fallback: Self.defaultPreprocessors(for: resolvedEventSource)
    )
  }

  var selectedActions: [AutomationPolicyAction] {
    selectedOrderedValues(AutomationPolicyAction.allCases, selectedRawValues: actions)
  }

  var resolvedActions: [AutomationPolicyAction] {
    orderedValues(
      AutomationPolicyAction.allCases,
      selectedRawValues: actions,
      fallback: [.recordMetadata]
    )
  }

  var selectedPostprocessors: [AutomationPolicyPostprocessor] {
    selectedOrderedValues(AutomationPolicyPostprocessor.allCases, selectedRawValues: postprocessors)
  }

  var resolvedPostprocessors: [AutomationPolicyPostprocessor] {
    orderedValues(
      AutomationPolicyPostprocessor.allCases,
      selectedRawValues: postprocessors,
      fallback: [.auditEvent]
    )
  }

  var resolvedSourceAppMode: AutomationSourceAppMode {
    AutomationSourceAppMode(rawValue: sourceAppMode) ?? .allExceptDenied
  }

  var resolvedSourceAppFilter: AutomationSourceAppFilter {
    AutomationSourceAppFilter(
      mode: resolvedSourceAppMode,
      allowedBundleIdentifiers: allowedBundleIdentifiers,
      deniedBundleIdentifiers: deniedBundleIdentifiers
    )
  }

  var resolvedOCRConfiguration: AutomationPolicyOCRConfiguration? {
    guard let ocrConfiguration else {
      return resolvedEventSource == .reviewScreenshotPaste
        ? AutomationPolicyOCRConfiguration()
        : nil
    }
    return AutomationPolicyOCRConfiguration(
      recognitionLevel: AutomationPolicyOCRConfiguration.RecognitionLevel(
        rawValue: ocrConfiguration.recognitionLevel
      ) ?? .accurate,
      automaticallyDetectsLanguage: ocrConfiguration.automaticallyDetectsLanguage,
      usesLanguageCorrection: ocrConfiguration.usesLanguageCorrection
    )
  }

  var resolvedReviewPullRequestExtraction: ReviewPullRequestExtractionConfiguration? {
    guard let reviewPullRequestExtraction else {
      return resolvedEventSource == .reviewScreenshotPaste
        ? ReviewPullRequestExtractionConfiguration()
        : nil
    }
    return ReviewPullRequestExtractionConfiguration(
      repositoryMode: ReviewPullRequestExtractionConfiguration.RepositoryMode(
        rawValue: reviewPullRequestExtraction.repositoryMode
      ) ?? .allConfiguredRepos,
      policyRepositories: reviewPullRequestExtraction.policyRepositories,
      numberMemoryEnabled: reviewPullRequestExtraction.numberMemoryEnabled,
      resultScope: ReviewPullRequestExtractionConfiguration.ResultScope(
        rawValue: reviewPullRequestExtraction.resultScope
      ) ?? .all,
      failureSignalMode: ReviewPullRequestExtractionConfiguration.FailureSignalMode(
        rawValue: reviewPullRequestExtraction.failureSignalMode
      ) ?? .liveOrVisual,
      outputFormat: ReviewPullRequestExtractionConfiguration.OutputFormat(
        rawValue: reviewPullRequestExtraction.outputFormat
      ) ?? .newlineGitHubURLs,
      autoCopy: reviewPullRequestExtraction.autoCopy,
      showSheet: reviewPullRequestExtraction.showSheet
    )
  }

  func automationPolicy(
    id: String,
    name: String,
    defaultPriority: Int
  ) -> AutomationPolicy {
    AutomationPolicy(
      id: id,
      name: name,
      eventSource: resolvedEventSource,
      isEnabled: isEnabled,
      priority: priority ?? defaultPriority,
      match: AutomationPolicyMatch(
        contentKinds: resolvedContentKinds,
        sourceAppFilter: resolvedSourceAppFilter
      ),
      preprocessors: resolvedPreprocessors,
      actions: resolvedActions,
      postprocessors: resolvedPostprocessors,
      ocrConfiguration: resolvedOCRConfiguration,
      reviewPullRequestExtraction: resolvedReviewPullRequestExtraction
    )
  }

  func replacingSource(_ source: AutomationPolicyEventSource) -> Self {
    var next = self
    next.eventSource = source.rawValue
    if next.preprocessors.isEmpty {
      next.preprocessors = Self.defaultPreprocessors(for: source).map(\.rawValue)
    }
    if source == .reviewScreenshotPaste {
      next.ocrConfiguration = next.ocrConfiguration ?? TaskBoardPolicyPipelineOCRConfiguration()
      next.reviewPullRequestExtraction =
        next.reviewPullRequestExtraction
        ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    }
    return next
  }

  func settingContentKind(_ kind: AutomationClipboardContentKind, enabled: Bool) -> Self {
    var next = self
    next.contentKinds = toggledRawValues(
      next.contentKinds,
      rawValue: kind.rawValue,
      enabled: enabled
    )
    return next
  }

  func settingPreprocessor(_ preprocessor: AutomationPolicyPreprocessor, enabled: Bool) -> Self {
    var next = self
    next.preprocessors = toggledRawValues(
      next.preprocessors,
      rawValue: preprocessor.rawValue,
      enabled: enabled
    )
    return next
  }

  func settingAction(_ action: AutomationPolicyAction, enabled: Bool) -> Self {
    var next = self
    next.actions = toggledRawValues(next.actions, rawValue: action.rawValue, enabled: enabled)
    return next
  }

  func settingPostprocessor(_ postprocessor: AutomationPolicyPostprocessor, enabled: Bool) -> Self {
    var next = self
    next.postprocessors = toggledRawValues(
      next.postprocessors,
      rawValue: postprocessor.rawValue,
      enabled: enabled
    )
    return next
  }

  func settingSourceAppMode(_ mode: AutomationSourceAppMode) -> Self {
    var next = self
    next.sourceAppMode = mode.rawValue
    return next
  }

  func settingAllowedBundleIdentifiers(_ identifiers: String) -> Self {
    var next = self
    next.allowedBundleIdentifiers = AutomationSourceAppFilter.normalizedIdentifiers([identifiers])
    return next
  }

  func settingDeniedBundleIdentifiers(_ identifiers: String) -> Self {
    var next = self
    next.deniedBundleIdentifiers = AutomationSourceAppFilter.normalizedIdentifiers([identifiers])
    return next
  }

  func settingOCRRecognitionLevel(
    _ level: AutomationPolicyOCRConfiguration.RecognitionLevel
  ) -> Self {
    var next = self
    var configuration = next.ocrConfiguration ?? TaskBoardPolicyPipelineOCRConfiguration()
    configuration.recognitionLevel = level.rawValue
    next.ocrConfiguration = configuration
    return next
  }

  func settingOCRAutomaticallyDetectsLanguage(_ enabled: Bool) -> Self {
    var next = self
    var configuration = next.ocrConfiguration ?? TaskBoardPolicyPipelineOCRConfiguration()
    configuration.automaticallyDetectsLanguage = enabled
    next.ocrConfiguration = configuration
    return next
  }

  func settingOCRUsesLanguageCorrection(_ enabled: Bool) -> Self {
    var next = self
    var configuration = next.ocrConfiguration ?? TaskBoardPolicyPipelineOCRConfiguration()
    configuration.usesLanguageCorrection = enabled
    next.ocrConfiguration = configuration
    return next
  }

  func settingReviewRepositoryMode(
    _ mode: ReviewPullRequestExtractionConfiguration.RepositoryMode
  ) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.repositoryMode = mode.rawValue
    next.reviewPullRequestExtraction = configuration
    return next
  }

  func settingReviewPolicyRepositories(_ repositories: String) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.policyRepositories = AutomationSourceAppFilter.normalizedIdentifiers([
      repositories
    ])
    next.reviewPullRequestExtraction = configuration
    return next
  }

  func settingReviewNumberMemoryEnabled(_ enabled: Bool) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.numberMemoryEnabled = enabled
    next.reviewPullRequestExtraction = configuration
    return next
  }

  func settingReviewResultScope(
    _ scope: ReviewPullRequestExtractionConfiguration.ResultScope
  ) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.resultScope = scope.rawValue
    next.reviewPullRequestExtraction = configuration
    return next
  }

  func settingReviewFailureSignalMode(
    _ mode: ReviewPullRequestExtractionConfiguration.FailureSignalMode
  ) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.failureSignalMode = mode.rawValue
    next.reviewPullRequestExtraction = configuration
    return next
  }

  func settingReviewOutputFormat(
    _ format: ReviewPullRequestExtractionConfiguration.OutputFormat
  ) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.outputFormat = format.rawValue
    next.reviewPullRequestExtraction = configuration
    return next
  }

  func settingReviewAutoCopy(_ enabled: Bool) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.autoCopy = enabled
    next.reviewPullRequestExtraction = configuration
    return next
  }

  func settingReviewShowSheet(_ enabled: Bool) -> Self {
    var next = self
    var configuration =
      next.reviewPullRequestExtraction ?? TaskBoardPolicyPipelineReviewPullRequestExtraction()
    configuration.showSheet = enabled
    next.reviewPullRequestExtraction = configuration
    return next
  }

}
