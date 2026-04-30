import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  @ViewBuilder var paneContent: some View {
    switch viewModel.selection {
    case .create:
      createPane
    case .decisions:
      decisionDeskPane
    case .decision:
      decisionDetailPane
    case .terminal:
      if let selectedSessionTui {
        sessionPane(selectedSessionTui)
      } else {
        unavailableSessionPane
      }
    case .codex:
      if let selectedCodexRun {
        codexPane(selectedCodexRun)
      } else {
        unavailableSessionPane
      }
    case .agent(_, let agentID):
      agentDetailPane(agentID: agentID)
    case .task(_, let taskID):
      taskDetailPane(taskID: taskID)
    }
  }

  @ViewBuilder var decisionDeskPane: some View {
    DecisionDetailView(
      selectedTab: decisionDetailTabBinding,
      observer: sessionObserver,
      decisionScope: decisionWorkspaceScope,
      primaryActionFocusDecisionID: store.supervisorPrimaryActionFocusDecisionID,
      primaryActionFocusRequestTick: store.supervisorPrimaryActionFocusRequestTick
    )
  }

  @ViewBuilder var decisionDetailPane: some View {
    if let selectedDecision {
      DecisionDetailView(
        decision: selectedDecision,
        store: store,
        handler: decisionActionHandler,
        auditEvents: decisionAuditEvents,
        selectedTab: decisionDetailTabBinding,
        observer: sessionObserver,
        primaryActionFocusDecisionID: store.supervisorPrimaryActionFocusDecisionID,
        primaryActionFocusRequestTick: store.supervisorPrimaryActionFocusRequestTick
      )
    } else {
      ContentUnavailableView(
        "Decision unavailable",
        systemImage: "bell.slash",
        description: Text("Refresh the workspace or pick another decision.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ToolbarContentBuilder var decisionToolbarItems: some ToolbarContent {
    if viewModel.selection.isDecisionRoute {
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          Button("Dismiss selected") {
            Task { await dismissSelectedDecision() }
          }
          .disabled(selectedDecision == nil)
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissSelected)

          Button("Dismiss all visible") {
            beginDismissAllVisible()
          }
          .disabled(visibleOpenDecisionIDs.isEmpty)
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissVisible)

          if let reopenBatch = currentReopenBatch {
            Button("Reopen dismissed batch") {
              Task { await reopenDismissedBatch(reopenBatch) }
            }
            .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkReopenBatch)
          }

          Button(
            decisionWorkspaceScope.hasActiveFilters
              ? "Snooze filtered critical for 1h"
              : "Snooze visible critical for 1h"
          ) {
            Task { await snoozeAllCritical() }
          }
          .disabled(criticalDecisionIDs.isEmpty)
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkSnoozeCritical)

          Button(
            decisionWorkspaceScope.hasActiveFilters
              ? "Dismiss filtered info"
              : "Dismiss visible info"
          ) {
            Task { await dismissAllInfo() }
          }
          .disabled(infoDecisionIDs.isEmpty)
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissInfo)
        } label: {
          Label("Bulk actions", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help("Decision bulk actions")
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkActions)

        Button {
          isDecisionInspectorVisible.toggle()
        } label: {
          Label(
            isDecisionInspectorVisible ? "Hide Inspector" : "Show Inspector",
            systemImage: "sidebar.right"
          )
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help(
          isDecisionInspectorVisible ? "Hide decision inspector" : "Show decision inspector"
        )
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionInspectorToggle)
      }
    }
  }
}
