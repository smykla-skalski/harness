import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  func prepareWorkspace() async {
    workspacePreparationComplete = false
    viewModel.windowNavigation.setHandlers(
      back: { navigateHistoryBack() },
      forward: { navigateHistoryForward() }
    )
    await Task.yield()
    await loadAgentPickerCatalogs()
    await reloadDecisions()
    resolveInitialWorkspaceSelection()
    await Task.yield()
    guard !Task.isCancelled else {
      return
    }
    workspacePreparationComplete = true
    enableStartupFocusParticipation()
  }

  func refreshWorkspaceAfterDataChange(afterRefresh: Bool = false) {
    refreshDisplayState()
    reconcileSheetState(afterRefresh: afterRefresh)
  }

  func handleSupervisorDecisionRefresh() {
    Task {
      await reloadDecisions()
      syncSupervisorDecisionRoute(recordHistory: false)
    }
  }

  func handleSelectedTuiChange(
    _ selectedTuiID: String?,
    viewModel: ViewModel
  ) {
    guard let selectedTuiID else {
      return
    }
    if viewModel.selection.terminalID == selectedTuiID,
      let currentSize = selectedSessionTui?.size
    {
      syncTerminalResizeControls(to: currentSize)
      if viewModel.expectedSize == nil {
        viewModel.expectedSize = currentSize
      }
      enforceExpectedSize()
    }
  }

  func enableStartupFocusParticipation() {
    guard !startupFocusParticipationActive else {
      return
    }
    startupFocusParticipationActive = true
  }
}
