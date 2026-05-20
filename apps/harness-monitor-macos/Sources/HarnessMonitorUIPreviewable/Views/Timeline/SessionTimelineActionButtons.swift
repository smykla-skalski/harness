import HarnessMonitorKit
import SwiftUI

struct SessionTimelineActionButtons: View {
  let actions: [SessionTimelineAction]
  let handler: any DecisionActionHandler
  @State private var confirmingCancelAction: SessionTimelineAction?

  var body: some View {
    if !actions.isEmpty {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        ForEach(actions) { action in
          if case .cancel = action.signalPayload {
            HarnessMonitorActionButton(
              title: action.title,
              tint: tint(for: action),
              variant: .bordered,
              accessibilityIdentifier: action.accessibilityIdentifier
            ) {
              confirmingCancelAction = action
            }
            .accessibilityLabel(actionAccessibilityLabel(action))
          } else {
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
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(groupAccessibilityLabel)
      .confirmationDialog(
        "Cancel signal?",
        isPresented: Binding(
          get: { confirmingCancelAction != nil },
          set: { if !$0 { confirmingCancelAction = nil } }
        ),
        presenting: confirmingCancelAction
      ) { action in
        Button("Cancel Signal", role: .destructive) {
          Task { await action.perform(using: handler) }
        }
        Button("Keep", role: .cancel) {}
      } message: { _ in
        Text("The signal will not be delivered")
      }
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
    switch action.signalPayload {
    case .cancel: return "Cancel signal"
    case .resend: return "Resend signal"
    case nil: return "\(action.title), decision \(action.decisionID)"
    }
  }
}

// High-severity-events trace surfaced 7 instances of this view at 9-13ms
// each: HarnessMonitorWrapLayout's per-body geometry pass is the cost.
// The action set is stable per row; gate body via Equatable so unchanged
// rows skip the layout work entirely. MainActor isolation matches the
// View's implicit @MainActor on body.
extension SessionTimelineActionButtons: @MainActor Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.actions == rhs.actions
      && ObjectIdentifier(lhs.handler as AnyObject)
        == ObjectIdentifier(rhs.handler as AnyObject)
  }
}
