import Foundation

extension AutomationPolicyCenter {
  func decision(
    for source: AutomationPolicyEventSource,
    contentKinds: Set<AutomationClipboardContentKind>,
    sourceApplication: AutomationSourceApplication? = nil,
    containsSensitiveContent: Bool = false,
    accessBehaviorDescription: String? = nil,
    allowsPasteboardPrompt: Bool = false
  ) -> AutomationPolicyDecision {
    let policies = document.policies(for: source)
    let fallbackPolicy = policies.first ?? AutomationPolicyDocument.defaultPolicy(for: source)
    guard document.isEnabled else {
      return AutomationPolicyDecision(
        policy: fallbackPolicy,
        isAllowed: false,
        reason: "Automation policies are disabled"
      )
    }
    let enabledPolicies = policies.filter(\.isEnabled)
    guard !enabledPolicies.isEmpty else {
      return AutomationPolicyDecision(
        policy: fallbackPolicy,
        isAllowed: false,
        reason: "No enabled \(source.title.lowercased()) policy"
      )
    }
    var lastRejectedDecision: AutomationPolicyDecision?
    let context = AutomationPolicyDecisionContext(
      contentKinds: contentKinds,
      sourceApplication: sourceApplication,
      containsSensitiveContent: containsSensitiveContent,
      accessBehaviorDescription: accessBehaviorDescription,
      allowsPasteboardPrompt: allowsPasteboardPrompt
    )
    for policy in enabledPolicies {
      if let reason = denialReason(for: policy, context: context) {
        lastRejectedDecision = AutomationPolicyDecision(
          policy: policy,
          isAllowed: false,
          reason: reason
        )
        continue
      }
      return AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
    }
    return lastRejectedDecision
      ?? AutomationPolicyDecision(
        policy: fallbackPolicy,
        isAllowed: false,
        reason: "No matching \(source.title.lowercased()) policy"
      )
  }

  private func denialReason(
    for policy: AutomationPolicy,
    context: AutomationPolicyDecisionContext
  ) -> String? {
    if policy.hasPreprocessor(.respectPasteboardPrivacy),
      context.accessBehaviorDescription == "alwaysDeny"
    {
      return "Pasteboard access is denied in System Settings"
    }
    if policy.hasPreprocessor(.respectPasteboardPrivacy), !context.allowsPasteboardPrompt,
      context.accessBehaviorDescription == "ask"
    {
      return "Pasteboard access requires confirmation"
    }
    if policy.hasPreprocessor(.skipSensitiveMarkers), context.containsSensitiveContent {
      return "Pasteboard item is marked concealed or transient"
    }
    if policy.hasPreprocessor(.filterSourceApplications),
      !policy.match.sourceAppFilter.allows(context.sourceApplication)
    {
      return "Source application is not allowed"
    }
    if policy.match.contentKinds.isDisjoint(with: context.contentKinds) {
      return "No matching content kinds"
    }
    return nil
  }
}

private struct AutomationPolicyDecisionContext {
  let contentKinds: Set<AutomationClipboardContentKind>
  let sourceApplication: AutomationSourceApplication?
  let containsSensitiveContent: Bool
  let accessBehaviorDescription: String?
  let allowsPasteboardPrompt: Bool
}
