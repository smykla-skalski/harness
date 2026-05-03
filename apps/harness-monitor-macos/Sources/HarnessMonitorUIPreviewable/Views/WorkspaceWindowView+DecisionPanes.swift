import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  @ViewBuilder
  func paneContent(decisionScope: DecisionWorkspaceScope) -> some View {
    switch viewModel.selection {
    case .create:
      createPane
    case .decisions:
      decisionDeskPane(decisionScope: decisionScope)
    case .decision:
      decisionDetailPane(decisionScope: decisionScope)
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

  @ViewBuilder
  func decisionDeskPane(decisionScope: DecisionWorkspaceScope) -> some View {
    DecisionDetailView(
      selectedTab: decisionDetailTabBinding,
      observer: sessionObserver,
      decisionScope: decisionScope,
      primaryActionFocusDecisionID: store.supervisorPrimaryActionFocusDecisionID,
      primaryActionFocusRequestTick: store.supervisorPrimaryActionFocusRequestTick,
      primaryContentFocusScope: currentPrimaryContentFocusScope,
      primaryContentPagingResponderRequest: currentPrimaryContentPagingRequest,
      prefersPrimaryContentFocus: currentPrimaryContentFocusTarget == .decisionDetail
    )
  }

  @ViewBuilder
  func decisionDetailPane(decisionScope: DecisionWorkspaceScope) -> some View {
    if let selectedDecision = decisionScope.selectedDecision {
      DecisionDetailView(
        decision: selectedDecision,
        store: store,
        handler: decisionActionHandler,
        auditEvents: decisionAuditEvents,
        selectedTab: decisionDetailTabBinding,
        observer: sessionObserver,
        primaryActionFocusDecisionID: store.supervisorPrimaryActionFocusDecisionID,
        primaryActionFocusRequestTick: store.supervisorPrimaryActionFocusRequestTick,
        primaryContentFocusScope: currentPrimaryContentFocusScope,
        primaryContentPagingResponderRequest: currentPrimaryContentPagingRequest,
        prefersPrimaryContentFocus: currentPrimaryContentFocusTarget == .decisionDetail
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

  @ToolbarContentBuilder
  func decisionToolbarItems(
    decisionScope: DecisionWorkspaceScope
  ) -> some ToolbarContent {
    if viewModel.selection.isDecisionRoute {
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          decisionBulkActionItems(decisionScope: decisionScope)
        } label: {
          Label("Bulk actions", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help("Decision bulk actions")
        .harnessMCPButton(
          HarnessMonitorAccessibility.decisionBulkActions,
          label: "Decision bulk actions"
        )

        Button {
          toggleDecisionInspector()
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
        .harnessMCPButton(
          HarnessMonitorAccessibility.decisionInspectorToggle,
          label: isDecisionInspectorVisible ? "Hide decision inspector" : "Show decision inspector",
          pressAction: toggleDecisionInspector
        )
      }
    }
  }

  @ViewBuilder
  private func decisionBulkActionItems(
    decisionScope: DecisionWorkspaceScope
  ) -> some View {
    Button("Dismiss selected") {
      Task { await dismissSelectedDecision() }
    }
    .disabled(decisionScope.selectedDecision == nil)
    .harnessMCPMenuItem(
      HarnessMonitorAccessibility.decisionBulkDismissSelected,
      label: "Dismiss selected decision",
      enabled: decisionScope.selectedDecision != nil,
      pressAction: { Task { await dismissSelectedDecision() } }
    )

    Button("Dismiss all visible") {
      beginDismissAllVisible()
    }
    .disabled(decisionScope.visibleDecisionIDs.isEmpty)
    .harnessMCPMenuItem(
      HarnessMonitorAccessibility.decisionBulkDismissVisible,
      label: "Dismiss all visible decisions",
      enabled: !decisionScope.visibleDecisionIDs.isEmpty,
      pressAction: beginDismissAllVisible
    )

    if let reopenBatch = currentReopenBatch {
      Button("Reopen dismissed batch") {
        Task { await reopenDismissedBatch(reopenBatch) }
      }
      .harnessMCPMenuItem(
        HarnessMonitorAccessibility.decisionBulkReopenBatch,
        label: "Reopen dismissed batch",
        pressAction: { Task { await reopenDismissedBatch(reopenBatch) } }
      )
    }

    Button(
      decisionScope.hasActiveFilters
        ? "Snooze filtered critical for 1h"
        : "Snooze visible critical for 1h"
    ) {
      Task { await snoozeAllCritical() }
    }
    .disabled(decisionScope.visibleCriticalDecisionIDs.isEmpty)
    .harnessMCPMenuItem(
      HarnessMonitorAccessibility.decisionBulkSnoozeCritical,
      label: decisionScope.hasActiveFilters
        ? "Snooze filtered critical for 1 hour"
        : "Snooze visible critical for 1 hour",
      enabled: !decisionScope.visibleCriticalDecisionIDs.isEmpty,
      pressAction: { Task { await snoozeAllCritical() } }
    )

    Button(
      decisionScope.hasActiveFilters
        ? "Dismiss filtered info"
        : "Dismiss visible info"
    ) {
      Task { await dismissAllInfo() }
    }
    .disabled(decisionScope.visibleInfoDecisionIDs.isEmpty)
    .harnessMCPMenuItem(
      HarnessMonitorAccessibility.decisionBulkDismissInfo,
      label: decisionScope.hasActiveFilters
        ? "Dismiss filtered info decisions"
        : "Dismiss visible info decisions",
      enabled: !decisionScope.visibleInfoDecisionIDs.isEmpty,
      pressAction: { Task { await dismissAllInfo() } }
    )
  }
}
