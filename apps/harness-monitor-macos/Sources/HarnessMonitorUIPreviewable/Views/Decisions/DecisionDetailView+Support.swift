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

func humanizedWorkspaceLabel(_ raw: String) -> String {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return raw
  }

  let separated = trimmed
    .replacingOccurrences(of: ".", with: " ")
    .replacingOccurrences(of: "_", with: " ")
    .replacingOccurrences(of: "-", with: " ")
  let collapsed = separated.replacingOccurrences(
    of: "\\s+",
    with: " ",
    options: .regularExpression
  )
  return collapsed.localizedCapitalized
}

func condensedWorkspacePath(_ path: String) -> String {
  let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
  return lastPathComponent.isEmpty ? path : lastPathComponent
}

func runtimeDisplayLabel(_ raw: String) -> String {
  if let runtime = AgentTuiRuntime(rawValue: raw) {
    return runtime.title
  }
  return humanizedWorkspaceLabel(raw)
}
