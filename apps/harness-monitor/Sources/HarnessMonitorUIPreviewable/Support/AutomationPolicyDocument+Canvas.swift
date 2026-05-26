import Foundation

extension AutomationPolicyDocument {
  public static let canvasPolicyIDPrefix = "canvas."

  public func replacingCanvasPolicies(_ canvasPolicies: [AutomationPolicy]) -> Self {
    let retainedPolicies = policies.filter {
      !$0.id.hasPrefix(Self.canvasPolicyIDPrefix)
    }
    return Self(
      version: version,
      isEnabled: isEnabled,
      policies: retainedPolicies + canvasPolicies,
      updatedAt: Date()
    )
  }
}
