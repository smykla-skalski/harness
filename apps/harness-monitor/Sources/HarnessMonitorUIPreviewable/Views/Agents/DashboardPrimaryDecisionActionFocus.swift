import HarnessMonitorKit
import SwiftUI

struct DashboardDecisionActionFocusTarget: Hashable {
  let decisionID: String
  let requestTick: Int

  static func resolve(
    decisionID: String,
    isPrimaryAction: Bool,
    selectedDecisionID: String?,
    requestTick: Int
  ) -> Self? {
    guard isPrimaryAction, requestTick != 0, selectedDecisionID == decisionID else {
      return nil
    }
    return Self(decisionID: decisionID, requestTick: requestTick)
  }
}

enum DashboardDecisionActionFocusPolicy {
  static func primaryActionID(in actions: [SuggestedAction]) -> String? {
    actions.first(where: isProminentAction)?.id ?? actions.first?.id
  }

  private static func isProminentAction(_ action: SuggestedAction) -> Bool {
    switch action.kind {
    case .dismiss, .snooze:
      false
    default:
      true
    }
  }
}

private struct DashboardPrimaryDecisionActionFocusModifier: ViewModifier {
  let store: HarnessMonitorStore
  let decisionID: String
  let isPrimaryAction: Bool
  @AccessibilityFocusState private var accessibilityFocused: Bool
  @FocusState private var keyboardFocused: Bool

  private var target: DashboardDecisionActionFocusTarget? {
    DashboardDecisionActionFocusTarget.resolve(
      decisionID: decisionID,
      isPrimaryAction: isPrimaryAction,
      selectedDecisionID: store.supervisorPrimaryActionFocusDecisionID,
      requestTick: store.supervisorPrimaryActionFocusRequestTick
    )
  }

  func body(content: Content) -> some View {
    content
      .focused($keyboardFocused)
      .accessibilityFocused($accessibilityFocused)
      .task(id: target) {
        guard target != nil else { return }
        for _ in 0..<4 {
          await Task.yield()
          guard !Task.isCancelled else { return }
          keyboardFocused = true
          accessibilityFocused = true
          do {
            try await Task.sleep(for: .milliseconds(50))
          } catch {
            return
          }
          guard !Task.isCancelled else { return }
          if keyboardFocused || accessibilityFocused { return }
        }
      }
  }
}

extension View {
  func dashboardPrimaryDecisionActionFocus(
    store: HarnessMonitorStore,
    decisionID: String,
    isPrimaryAction: Bool
  ) -> some View {
    modifier(
      DashboardPrimaryDecisionActionFocusModifier(
        store: store,
        decisionID: decisionID,
        isPrimaryAction: isPrimaryAction
      )
    )
  }
}
