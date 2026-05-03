import HarnessMonitorKit
import SwiftUI

extension DecisionDetailView {
  func suggestedActions(
    _ viewModel: DecisionDetailViewModel,
    contextAdapter: DecisionKindContextAdapter
  ) -> some View {
    let effectiveActions = contextAdapter.suggestedActions(from: viewModel.suggestedActions)
    let primaryActionID = primaryActionID(for: effectiveActions)
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Suggested Actions")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if effectiveActions.isEmpty {
        Text("No actions are available for this decision yet.")
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        actionButtonGroup(
          actions: effectiveActions,
          primaryActionID: primaryActionID,
          viewModel: viewModel,
          contextAdapter: contextAdapter
        )
      }
    }
  }

  @ViewBuilder
  func actionButtonGroup(
    actions: [SuggestedAction],
    primaryActionID: String?,
    viewModel: DecisionDetailViewModel,
    contextAdapter: DecisionKindContextAdapter
  ) -> some View {
    let emphasizedPrimaryActionID =
      primaryActionID.flatMap { candidateID in
        actions.first { $0.id == candidateID && isProminentActionCandidate($0) }?.id
      }
    let wrappedActions = actions.filter { $0.id != emphasizedPrimaryActionID }

    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      if let emphasizedPrimaryActionID,
        let primaryAction = actions.first(where: { $0.id == emphasizedPrimaryActionID })
      {
        actionButton(
          for: primaryAction,
          viewModel: viewModel,
          contextAdapter: contextAdapter,
          isPrimaryFocusTarget: primaryActionID == emphasizedPrimaryActionID,
          emphasizesAction: true,
          fillsWidth: true
        )
      }
      if !wrappedActions.isEmpty {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.spacingXS
        ) {
          ForEach(wrappedActions) { action in
            actionButton(
              for: action,
              viewModel: viewModel,
              contextAdapter: contextAdapter,
              isPrimaryFocusTarget: action.id == primaryActionID,
              emphasizesAction: false
            )
          }
        }
      }
    }
  }
}
