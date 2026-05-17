import HarnessMonitorKit
import SwiftUI

struct SessionWindowDecisionsList: View {
  let decisions: [Decision]
  let decisionIDs: [String]
  let currentModifiers: EventModifiers
  @Bindable var state: SessionWindowStateCache
  @Environment(\.fontScale)
  private var fontScale
  @State private var routeSelection = SessionRouteListSelectionState()

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var preferredRouteDetailDecisionID: String? {
    if case .route(.decisions) = state.selection {
      return SessionDecisionAutoSelectionPolicy.preferredRouteDetailDecisionID(
        rememberedDecisionID: state.sectionState.decisionID,
        allDecisionIDs: Set(decisionIDs),
        visibleDecisionIDs: decisionIDs
      )
    }
    return state.selection.decisionID
  }

  private var selectedDecisionIDs: Binding<Set<String>> {
    Binding(
      get: {
        routeSelection.displayedSelection(fallbackPrimaryID: preferredRouteDetailDecisionID)
      },
      set: { newSelection in
        applyDecisionSelection(newSelection)
      }
    )
  }

  var body: some View {
    List(selection: selectedDecisionIDs) {
      if decisions.isEmpty {
        ContentUnavailableView(
          emptyStateTitle,
          systemImage: "exclamationmark.bubble",
          description: Text(emptyStateDescription)
        )
      } else {
        ForEach(decisions) { decision in
          VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
            Text(decision.summary)
              .scaledFont(.body)
              .lineLimit(1)
            Text("\(decisionSeverityLabel(for: decision)) - \(decision.ruleID)")
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(decision.id)
          .contentShape(Rectangle())
          .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
              collapseToRowFromPlainTap(decision.id)
            },
            including: hasActiveMultiSelection ? .gesture : []
          )
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel(decisionAccessibilityLabel(for: decision))
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionRow(decision.id))
          .contextMenu {
            SessionDecisionContextMenuActions(
              resolution: .actionable(
                SessionSidebarContextMenuScope.resolve(
                  kind: .decision,
                  rowID: decision.id,
                  selectedIDs: selectedDecisionIDs.wrappedValue,
                  orderedVisibleIDs: decisionIDs
                )
              )
            )
          }
          .harnessMCPRow(
            HarnessMonitorAccessibility.decisionRow(decision.id),
            label: decisionAccessibilityLabel(for: decision),
            value:
              selectedDecisionIDs.wrappedValue.contains(decision.id) ? "selected" : "not selected",
            pressAction: {
              applyDecisionSelection([decision.id])
            }
          )
        }
      }
    }
    .listStyle(.inset)
    .onChange(of: decisionIDs) { _, ids in
      let primaryID = routeSelection.prune(
        visibleIDs: Set(ids),
        fallbackPrimaryID: preferredRouteDetailDecisionID
      )
      syncPrimaryDecisionSelection(primaryID)
    }
    .onChange(of: preferredRouteDetailDecisionID) { _, primaryID in
      guard !hasActiveMultiSelection else { return }
      routeSelection.collapse(to: primaryID)
    }
    .onChange(of: state.lastPlainClick) { _, signal in
      collapseSelectionFromApplicationTap(signal)
    }
  }

  private func decisionAccessibilityLabel(for decision: Decision) -> String {
    "\(decisionSeverityLabel(for: decision)). \(decision.summary). \(decision.ruleID)"
  }

  private var emptyStateTitle: String {
    hasActiveFilters ? "No Matching Decisions" : "No Pending Decisions"
  }

  private var emptyStateDescription: String {
    if hasActiveFilters {
      return
        "Clear or broaden the current filters to bring this session's decisions back into view."
    }
    return "This session has no open decisions right now."
  }

  private var hasActiveFilters: Bool {
    let query = state.decisionFilters.query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !query.isEmpty || !state.decisionFilters.severities.isEmpty
  }

  private func decisionSeverityLabel(for decision: Decision) -> String {
    DecisionSeverity(rawValue: decision.severityRaw)?.chipLabel ?? "Decision"
  }

  private var hasActiveMultiSelection: Bool {
    routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailDecisionID)
  }

  private func applyDecisionSelection(_ newSelection: Set<String>) {
    let primaryID = routeSelection.applySelection(
      newSelection,
      fallbackPrimaryID: preferredRouteDetailDecisionID
    )
    syncPrimaryDecisionSelection(primaryID)
  }

  private func syncPrimaryDecisionSelection(_ primaryID: String?) {
    if routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailDecisionID) {
      state.selectRoute(.decisions)
      state.setRouteDecisionID(primaryID)
      return
    }

    guard let primaryID else {
      if case .route(.decisions) = state.selection {
        state.setRouteDecisionID(nil)
      }
      return
    }

    if case .route(.decisions) = state.selection {
      guard primaryID != state.sectionState.decisionID else { return }
      state.setRouteDecisionID(primaryID)
    } else {
      guard primaryID != state.selection.decisionID else { return }
      state.selectDecision(primaryID)
    }
  }

  private func collapseToRowFromPlainTap(_ decisionID: String) {
    let blocking = currentModifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: decisionID)
    syncPrimaryDecisionSelection(decisionID)
  }

  private func collapseSelectionFromApplicationTap(_ signal: SessionPlainClickSignal) {
    let blocking = signal.modifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: preferredRouteDetailDecisionID)
  }
}

public struct DecisionDetailSummary: View {
  let decision: Decision
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  public init(decision: Decision) {
    self.decision = decision
  }

  public var body: some View {
    Form {
      LabeledContent("Summary", value: decision.summary)
      LabeledContent("Rule", value: decision.ruleID)
      LabeledContent("Severity", value: decision.severityRaw)
      if let agentID = decision.agentID {
        LabeledContent("Agent", value: agentID)
      }
      if let taskID = decision.taskID {
        LabeledContent("Task", value: taskID)
      }
    }
    .formStyle(.grouped)
    .padding(metrics.contentPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }
}
