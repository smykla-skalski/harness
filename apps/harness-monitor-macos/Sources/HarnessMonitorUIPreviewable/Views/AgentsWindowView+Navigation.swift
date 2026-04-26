import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  func applyProgrammaticSelection(_ nextSelection: AgentTuiSheetSelection) {
    guard viewModel.selection != nextSelection else {
      if nextSelection.terminalID != nil {
        enforceExpectedSize()
      }
      return
    }
    viewModel.suppressHistoryRecording = true
    viewModel.selection = nextSelection
    if nextSelection.terminalID != nil {
      enforceExpectedSize()
    }
  }

  func navigateHistoryBack() {
    guard !viewModel.navigationBackStack.isEmpty else { return }
    let destination = viewModel.navigationBackStack.removeLast()
    viewModel.navigationForwardStack.append(viewModel.selection)
    viewModel.suppressHistoryRecording = true
    viewModel.selection = destination
    updateNavigationState()
  }

  func navigateHistoryForward() {
    guard !viewModel.navigationForwardStack.isEmpty else { return }
    let destination = viewModel.navigationForwardStack.removeLast()
    viewModel.navigationBackStack.append(viewModel.selection)
    viewModel.suppressHistoryRecording = true
    viewModel.selection = destination
    updateNavigationState()
  }

  func updateNavigationState() {
    let canGoBack = !viewModel.navigationBackStack.isEmpty
    let canGoForward = !viewModel.navigationForwardStack.isEmpty
    guard
      viewModel.windowNavigation.canGoBack != canGoBack
        || viewModel.windowNavigation.canGoForward != canGoForward
    else {
      return
    }
    viewModel.windowNavigation = viewModel.windowNavigation.updating(
      canGoBack: canGoBack,
      canGoForward: canGoForward
    )
    navigationBridge.update(viewModel.windowNavigation)
  }
}
