import HarnessMonitorKit
import SwiftUI

extension SessionSidebar {
  @ViewBuilder var decisionsSection: some View {
    Section {
      let orderedDecisionIDs = decisions.map(\.id)
      ForEach(decisions) { decision in
        let selection = SessionSelection.decision(
          sessionID: state.sessionID,
          decisionID: decision.id
        )
        let severity = DecisionSeverity(rawValue: decision.severityRaw)
        SessionSidebarRow(
          title: decision.summary,
          systemImage: "exclamationmark.bubble",
          severityShape: severityShape(for: severity),
          severityTint: severityTint(for: severity)
        )
        .accessibilityLabel(sidebarDecisionAccessibilityLabel(for: decision, severity: severity))
        .tag(selection)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarDecisionRow(decision.id))
        .simultaneousGesture(
          SpatialTapGesture().onEnded { _ in
            collapseToRowFromPlainTap(selection)
          },
          including: hasActiveMultiSelection ? .gesture : []
        )
        .contextMenu {
          let resolution = SessionSidebarContextMenuScope.resolve(
            kind: .decision,
            rowID: decision.id,
            selectionState: .init(
              rowSelection: selection,
              listSelection: displayedSelectionSet
            ),
            selectedIDs: state.sidebarSelection.selectedDecisionIDs,
            orderedVisibleIDs: orderedDecisionIDs
          )
          SessionDecisionContextMenuActions(resolution: resolution)
        }
      }
      if decisions.isEmpty {
        Text("No pending decisions")
          .foregroundStyle(.secondary)
      }
    } header: {
      decisionsHeader
    }
  }

  var decisionsHeader: some View {
    HStack(alignment: .sessionSidebarHeaderButtonCenter, spacing: 6) {
      Text("Decisions")
      if state.sectionState.hasDraft(.decision) {
        Image(systemName: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unsaved draft")
      }
      Spacer()
      SessionSidebarHeaderCreateButton(
        state: state,
        kind: .decision,
        accessibilityLabel: "New Decision"
      )
    }
  }

  private func sidebarDecisionAccessibilityLabel(
    for decision: Decision,
    severity: DecisionSeverity?
  ) -> String {
    let severityLabel = severity?.chipLabel ?? "Decision"
    return "\(severityLabel). \(decision.summary). \(decision.ruleID)"
  }
}
