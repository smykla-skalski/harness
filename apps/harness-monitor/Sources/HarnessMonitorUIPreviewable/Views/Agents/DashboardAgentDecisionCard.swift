import HarnessMonitorKit
import SwiftUI

/// A supervisor or manual decision rendered inside Dashboard Agents. Resolution runs through the
/// shared action handler, which runs the chosen action against the daemon and only clears the row
/// once the daemon accepts, so a rejected or failed action leaves the card in place for a retry.
struct DashboardAgentDecisionCard: View {
  let store: HarnessMonitorStore
  let item: DashboardDecisionItem
  @State private var isResolving = false
  @State private var isPresentingSnooze = false

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      header
      Text(item.summary.withoutTrailingPeriod)
        .scaledFont(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !item.suggestedActions.isEmpty {
        actionRow
      } else {
        Text("This decision stays pending until the daemon accepts a resolution")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      item.severity.chipColor.opacity(0.08),
      in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
        .strokeBorder(item.severity.chipColor.opacity(0.22))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentDecisionCard(item.id))
    .confirmationDialog(
      "Snooze Decision",
      isPresented: $isPresentingSnooze,
      titleVisibility: .visible
    ) {
      ForEach(SnoozeOption.allCases) { option in
        Button(option.actionTitle) {
          snooze(duration: option.duration)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Pause this decision for a fixed interval")
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: item.kind.dashboardSystemImage)
        .foregroundStyle(item.severity.chipColor)
      Text(item.kind.dashboardTitle)
        .scaledFont(.subheadline.weight(.semibold))
      Spacer()
      Text(item.severity.chipLabel)
        .scaledFont(.caption2.weight(.semibold))
        .foregroundStyle(item.severity.chipColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(item.severity.chipColor.opacity(0.16), in: Capsule())
    }
  }

  private var actionRow: some View {
    HStack(spacing: 8) {
      if isResolving {
        ProgressView().controlSize(.small)
      }
      Spacer()
      ForEach(item.suggestedActions) { action in
        Button(action.title, role: action.isDashboardDestructive ? .destructive : nil) {
          perform(action)
        }
        .disabled(isResolving)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.dashboardAgentDecisionAction(item.id, action.id)
        )
      }
    }
  }

  private func perform(_ action: SuggestedAction) {
    guard !isResolving else { return }
    switch DashboardDecisionActionRoute(action: action) {
    case .resolve(let actionID):
      resolve(actionID)
    case .dismiss:
      dismiss()
    case .snooze:
      isPresentingSnooze = true
    }
  }

  private func resolve(_ actionID: String) {
    isResolving = true
    let decisionID = item.id
    let outcome = DecisionOutcome(chosenActionID: actionID, note: nil)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Resolving decision") {
        await store.resolveDashboardSupervisorDecision(decisionID: decisionID, outcome: outcome)
        await MainActor.run { isResolving = false }
      }
    )
  }

  private func dismiss() {
    isResolving = true
    let decisionID = item.id
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Dismissing decision") {
        await store.dismissDashboardSupervisorDecision(decisionID: decisionID)
        await MainActor.run { isResolving = false }
      }
    )
  }

  private func snooze(duration: TimeInterval) {
    isResolving = true
    let decisionID = item.id
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Snoozing decision") {
        await store.snoozeDashboardSupervisorDecision(
          decisionID: decisionID,
          duration: duration
        )
        await MainActor.run { isResolving = false }
      }
    )
  }
}

enum DashboardDecisionActionRoute: Equatable {
  case resolve(actionID: String)
  case dismiss
  case snooze

  init(action: SuggestedAction) {
    switch action.kind {
    case .dismiss:
      self = .dismiss
    case .snooze:
      self = .snooze
    default:
      self = .resolve(actionID: action.id)
    }
  }
}

extension DashboardDecisionKind {
  var dashboardTitle: String {
    switch self {
    case .acpPermission: "Permission request"
    case .codexApproval: "Approval request"
    case .manual: "Manual decision"
    case .supervisor: "Supervisor decision"
    }
  }

  var dashboardSystemImage: String {
    switch self {
    case .acpPermission: "shield.lefthalf.filled"
    case .codexApproval: "checkmark.seal"
    case .manual: "hand.raised"
    case .supervisor: "exclamationmark.bubble"
    }
  }
}

extension SuggestedAction {
  /// Drop and dismiss actions discard work, so they render as destructive controls.
  var isDashboardDestructive: Bool {
    kind == .dropTask || kind == .dismiss
  }
}

extension HarnessMonitorAccessibility {
  public static func dashboardAgentDecisionCard(_ decisionID: String) -> String {
    "harness.dashboard.agents.decision.\(slug(decisionID))"
  }

  public static func dashboardAgentDecisionAction(
    _ decisionID: String,
    _ actionID: String
  ) -> String {
    "harness.dashboard.agents.decision.\(slug(decisionID)).action.\(slug(actionID))"
  }
}
