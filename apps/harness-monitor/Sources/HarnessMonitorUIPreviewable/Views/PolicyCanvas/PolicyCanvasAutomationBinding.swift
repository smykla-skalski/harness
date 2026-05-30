import HarnessMonitorKit

extension TaskBoardPolicyPipelineAutomationBinding {
  static func canvasDefault(
    source: AutomationPolicyEventSource = .clipboard
  ) -> TaskBoardPolicyPipelineAutomationBinding {
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
      postprocessors: resolvedPostprocessors
    )
  }

  func replacingSource(_ source: AutomationPolicyEventSource) -> Self {
    var next = self
    next.eventSource = source.rawValue
    if next.preprocessors.isEmpty {
      next.preprocessors = Self.defaultPreprocessors(for: source).map(\.rawValue)
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

  private static func defaultPreprocessors(
    for source: AutomationPolicyEventSource
  ) -> [AutomationPolicyPreprocessor] {
    switch source {
    case .clipboard:
      [
        .respectPasteboardPrivacy,
        .skipSensitiveMarkers,
        .filterSourceApplications,
        .dedupeByFingerprint,
      ]
    case .manualReviewTextPaste:
      [.normalizeGitHubPullRequestLinks, .dedupePullRequests]
    case .manualOCRPaste, .ocrDrop, .ocrFilePicker, .screenshotFolder:
      [.dedupeByFingerprint]
    }
  }
}

private func selectedOrderedValues<Value>(
  _ allValues: [Value],
  selectedRawValues: [String]
) -> [Value] where Value: RawRepresentable, Value.RawValue == String {
  let selected = Set(selectedRawValues)
  return allValues.filter { selected.contains($0.rawValue) }
}

private func orderedValues<Value>(
  _ allValues: [Value],
  selectedRawValues: [String],
  fallback: [Value]
) -> [Value] where Value: RawRepresentable, Value.RawValue == String, Value: Equatable {
  let selected = Set(selectedRawValues)
  let values = allValues.filter { selected.contains($0.rawValue) }
  return values.isEmpty ? fallback : values
}

private func toggledRawValues(
  _ rawValues: [String],
  rawValue: String,
  enabled: Bool
) -> [String] {
  var values = rawValues.filter { !$0.isEmpty }
  if enabled {
    if !values.contains(rawValue) {
      values.append(rawValue)
    }
    return values
  }
  return values.filter { $0 != rawValue }
}
