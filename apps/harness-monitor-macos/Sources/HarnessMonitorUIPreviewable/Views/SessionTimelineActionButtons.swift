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
      .accessibilityLabel("Decision actions")
    }
  }

  private func tint(for action: SessionTimelineAction) -> Color? {
    switch action.kind {
    case .dismiss:
      HarnessMonitorTheme.danger
    case .snooze:
      HarnessMonitorTheme.caution
    default:
      action.isPrimary ? HarnessMonitorTheme.accent : nil
    }
  }

  private func actionAccessibilityLabel(_ action: SessionTimelineAction) -> String {
    "\(action.title), decision \(action.decisionID)"
  }
}
