import HarnessMonitorKit

struct PolicyCanvasAutomationSource {
  let node: PolicyCanvasNode
  let eventSource: AutomationPolicyEventSource
  let binding: TaskBoardPolicyPipelineAutomationBinding?
}

struct PolicyCanvasAutomationPolicyContribution: Equatable {
  var contentKinds: Set<AutomationClipboardContentKind> = []
  var preprocessors: [AutomationPolicyPreprocessor] = []
  var actions: [AutomationPolicyAction] = []
  var postprocessors: [AutomationPolicyPostprocessor] = []
  var sourceAppFilter: AutomationSourceAppFilter?
  var dryRun = false

  var isEmpty: Bool {
    contentKinds.isEmpty
      && preprocessors.isEmpty
      && actions.isEmpty
      && postprocessors.isEmpty
      && sourceAppFilter == nil
      && !dryRun
  }

  mutating func merge(_ other: Self) {
    contentKinds.formUnion(other.contentKinds)
    preprocessors = orderedUnion(
      AutomationPolicyPreprocessor.allCases,
      preprocessors,
      other.preprocessors
    )
    actions = orderedUnion(AutomationPolicyAction.allCases, actions, other.actions)
    postprocessors = orderedUnion(
      AutomationPolicyPostprocessor.allCases,
      postprocessors,
      other.postprocessors
    )
    sourceAppFilter = mergeSourceAppFilters(sourceAppFilter, other.sourceAppFilter)
    dryRun = dryRun || other.dryRun
  }
}

extension PolicyCanvasAutomationPolicyContribution {
  init(binding: TaskBoardPolicyPipelineAutomationBinding) {
    contentKinds = binding.selectedContentKinds
    preprocessors = binding.selectedPreprocessors
    actions = binding.selectedActions
    postprocessors = binding.selectedPostprocessors

    let hasSourceAppConfiguration =
      preprocessors.contains(.filterSourceApplications)
      || binding.resolvedSourceAppMode != .allExceptDenied
      || !binding.allowedBundleIdentifiers.isEmpty
      || !binding.deniedBundleIdentifiers.isEmpty
    if hasSourceAppConfiguration {
      sourceAppFilter = binding.resolvedSourceAppFilter
      if !preprocessors.contains(.filterSourceApplications) {
        preprocessors = orderedUnion(
          AutomationPolicyPreprocessor.allCases,
          preprocessors,
          [.filterSourceApplications]
        )
      }
    }
  }
}

extension AutomationPolicy {
  func applying(_ contribution: PolicyCanvasAutomationPolicyContribution) -> AutomationPolicy {
    guard !contribution.isEmpty else {
      return self
    }
    var policy = self
    policy.match.contentKinds.formUnion(contribution.contentKinds)
    policy.preprocessors = orderedUnion(
      AutomationPolicyPreprocessor.allCases,
      policy.preprocessors,
      contribution.preprocessors
    )
    policy.actions = orderedUnion(
      AutomationPolicyAction.allCases,
      policy.actions,
      contribution.actions
    )
    policy.postprocessors = orderedUnion(
      AutomationPolicyPostprocessor.allCases,
      policy.postprocessors,
      contribution.postprocessors
    )
    if let sourceAppFilter = contribution.sourceAppFilter {
      policy.match.sourceAppFilter =
        mergeSourceAppFilters(policy.match.sourceAppFilter, sourceAppFilter)
        ?? policy.match.sourceAppFilter
    }
    if contribution.dryRun {
      policy.dryRun = true
    }
    return policy
  }
}

extension PolicyCanvasAutomationPolicyCompiler {
  static func automationContribution(
    from reachableNodes: [PolicyCanvasNode],
    sourceNodeID: String
  ) -> PolicyCanvasAutomationPolicyContribution {
    var contribution = PolicyCanvasAutomationPolicyContribution()
    for node in reachableNodes where node.id != sourceNodeID {
      if node.kind == .dryRunGate || node.policyKind?.kind == "dry_run_gate" {
        contribution.dryRun = true
      }
      guard let binding = node.automationBinding, binding.isEnabled else {
        continue
      }
      contribution.merge(PolicyCanvasAutomationPolicyContribution(binding: binding))
    }
    return contribution
  }
}

private func mergeSourceAppFilters(
  _ left: AutomationSourceAppFilter?,
  _ right: AutomationSourceAppFilter?
) -> AutomationSourceAppFilter? {
  guard let left else {
    return right
  }
  guard let right else {
    return left
  }
  return AutomationSourceAppFilter(
    mode: left.mode == .allowedOnly || right.mode == .allowedOnly ? .allowedOnly : .allExceptDenied,
    allowedBundleIdentifiers: left.allowedBundleIdentifiers + right.allowedBundleIdentifiers,
    deniedBundleIdentifiers: left.deniedBundleIdentifiers + right.deniedBundleIdentifiers
  )
}

private func orderedUnion<Value>(
  _ allValues: [Value],
  _ left: [Value],
  _ right: [Value]
) -> [Value] where Value: Equatable {
  allValues.filter { left.contains($0) || right.contains($0) }
}
