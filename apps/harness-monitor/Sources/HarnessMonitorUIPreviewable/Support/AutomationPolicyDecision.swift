import Foundation

struct AutomationPolicyDecision: Equatable, Sendable {
  let policy: AutomationPolicy
  let isAllowed: Bool
  let reason: String?

  var shouldOCRImages: Bool {
    isAllowed && policy.hasAction(.ocrImage)
  }

  var shouldRememberRecentScan: Bool {
    isAllowed && policy.hasAction(.rememberRecentScan)
  }

  var shouldShowFeedback: Bool {
    isAllowed && policy.hasAction(.showFeedback)
  }

  var shouldOpenDashboardDebugging: Bool {
    isAllowed && policy.hasAction(.openDashboardDebugging)
  }

  var shouldRecordMetadata: Bool {
    isAllowed && policy.hasAction(.recordMetadata)
  }

  var shouldApplySourceSpecificTextCleanup: Bool {
    isAllowed && policy.postprocessors.contains(.sourceSpecificTextCleanup)
  }

  var shouldPersistResult: Bool {
    isAllowed && policy.postprocessors.contains(.persistResult)
  }

  var shouldAuditEvent: Bool {
    policy.postprocessors.contains(.auditEvent)
  }
}
