import HarnessMonitorKit
import SwiftUI

struct SessionTimelineActionButtons: View {
  let actions: [SessionTimelineAction]
  let handler: any DecisionActionHandler

  var body: some View {
    if !actions.isEmpty {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        ForEach(actions) { action in
          HarnessMonitorAsyncActionButton(
            title: action.title,
            tint: tint(for: action),
            variant: action.isPrimary ? .prominent : .bordered,
            role: action.role,
            isLoading: false,
            accessibilityIdentifier: action.accessibilityIdentifier
          ) {
            await action.perform(using: handler)
          }
          .accessibilityLabel(actionAccessibilityLabel(action))
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(groupAccessibilityLabel)
    }
  }

  private var groupAccessibilityLabel: String {
    actions.first?.signalPayload != nil ? "Signal actions" : "Decision actions"
  }

  private func tint(for action: SessionTimelineAction) -> Color? {
    if action.signalPayload != nil {
      return action.isPrimary ? HarnessMonitorTheme.accent : nil
    }
    switch action.kind {
    case .dismiss:
      return HarnessMonitorTheme.danger
    case .snooze:
      return HarnessMonitorTheme.caution
    default:
      return action.isPrimary ? HarnessMonitorTheme.accent : nil
    }
  }

  private func actionAccessibilityLabel(_ action: SessionTimelineAction) -> String {
    if action.signalPayload != nil { return action.title }
    return "\(action.title), decision \(action.decisionID)"
  }
}
