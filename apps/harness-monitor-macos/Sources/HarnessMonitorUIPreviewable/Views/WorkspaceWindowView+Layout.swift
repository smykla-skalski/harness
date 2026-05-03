import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  func applyDismissAllVisibleDialog<Content: View>(to content: Content) -> some View {
    content.confirmationDialog(
      "Dismiss all visible decisions",
      isPresented: showDismissAllVisibleConfirmationBinding,
      titleVisibility: .visible
    ) {
      TextField(
        "Type \(currentPendingDismissBatch?.count ?? 0) to confirm",
        text: dismissAllVisibleDraftBinding
      )
      .harnessMCPTextField(
        HarnessMonitorAccessibility.decisionBulkDismissVisibleInput,
        label: "Dismiss all visible decision confirmation",
        value: dismissAllVisibleDraftText
      )
      Button("Dismiss selected visible") {
        Task { await confirmDismissAllVisible() }
      }
      .disabled(dismissAllVisibleDraftText != "\(currentPendingDismissBatch?.count ?? -1)")
      .harnessMCPButton(
        HarnessMonitorAccessibility.decisionBulkDismissVisibleConfirm,
        label: "Dismiss selected visible decisions",
        enabled: dismissAllVisibleDraftText == "\(currentPendingDismissBatch?.count ?? -1)",
        pressAction: { Task { await confirmDismissAllVisible() } }
      )
      Button("Cancel", role: .cancel) {}
        .harnessMCPButton(
          HarnessMonitorAccessibility.decisionBulkDismissVisibleCancel,
          label: "Cancel dismiss all visible decisions",
          pressAction: { showsDismissAllVisibleConfirmation = false }
        )
    } message: {
      Text(dismissConfirmationMessage)
    }
  }

  func workspaceSplitView(
    displayState: AgentTuiDisplayState,
    decisionScope: DecisionWorkspaceScope,
    selection: Binding<WorkspaceSelection>
  ) -> some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      WorkspaceSidebar(
        store: store,
        selection: selection,
        decisionFilters: decisionFiltersBinding,
        columnVisibility: columnVisibilityBinding,
        isStartupFocusParticipationEnabled: startupFocusParticipationEnabled,
        decisionScope: decisionScope,
        currentSessionID: store.selectedSessionID,
        currentSessionTitle: store.selectedSession?.session.title,
        agentTuis: displayState.sortedAgentTuis,
        sessionTitlesByID: displayState.sessionTitlesByID,
        codexRuns: displayState.sortedCodexRuns,
        codexTitlesByID: displayState.codexTitlesByID,
        externalAgents: displayState.externalAgents,
        pendingDecisionAttention: pendingDecisionAttentionByAgentID,
        openPendingDecisions: openPendingDecisions,
        tasks: store.selectedSession?.tasks ?? [],
        refresh: refresh
      )
      .navigationSplitViewColumnWidth(
        min: WorkspaceChromeMetrics.sidebarMinWidth,
        ideal: WorkspaceChromeMetrics.sidebarIdealWidth,
        max: WorkspaceChromeMetrics.sidebarMaxWidth
      )
      .toolbarBaselineFrame(.sidebar)
    } detail: {
      detailSplitViewContent(decisionScope: decisionScope)
    }
  }

  @ViewBuilder
  func detailSplitViewContent(
    decisionScope: DecisionWorkspaceScope
  ) -> some View {
    HStack(spacing: 0) {
      detailColumnContent(decisionScope: decisionScope)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if viewModel.selection.isDecisionRoute, isDecisionInspectorVisible {
        Divider()
        DecisionInspector(
          decision: decisionScope.selectedDecision,
          liveTick: decisionLiveTick
        )
        .frame(
          width: WorkspaceChromeMetrics.decisionInspectorWidth,
          alignment: .topLeading
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.windowBackground)
      }
    }
  }
}
