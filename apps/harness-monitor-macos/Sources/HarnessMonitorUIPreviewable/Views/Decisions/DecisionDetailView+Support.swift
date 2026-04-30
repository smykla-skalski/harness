import HarnessMonitorKit
import SwiftUI

extension DecisionDetailView {
  func primaryActionID(for actions: [SuggestedAction]) -> String? {
    actions.first(where: isProminentActionCandidate)?.id ?? actions.first?.id
  }

  func isProminentActionCandidate(_ action: SuggestedAction) -> Bool {
    switch action.kind {
    case .dismiss, .snooze:
      false
    default:
      true
    }
  }

  func tint(for action: SuggestedAction, severity: DecisionSeverity) -> Color? {
    switch action.kind {
    case .dismiss:
      return HarnessMonitorTheme.danger
    case .snooze:
      return HarnessMonitorTheme.caution
    default:
      if severity == .critical || severity == .needsUser {
        return HarnessMonitorTheme.accent
      }
      return nil
    }
  }
}
