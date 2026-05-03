import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  @discardableResult
  func consumePendingWorkspaceSelection() -> Bool {
    guard let pending = store.consumePendingWorkspaceSelectionRequest() else {
      return false
    }
    if case .create = pending.selection, let createEntryPoint = pending.createEntryPoint {
      applyWorkspaceCreateEntryPoint(createEntryPoint)
    }
    if pending.resetDecisionFilters {
      WorkspaceDecisionFilterDefaults.reset()
      decisionFilters = Self.initialDecisionFilters
    }
    applyProgrammaticSelection(pending.selection, recordHistory: true)
    return true
  }

  func resolveInitialWorkspaceSelection() {
    _ = consumePendingWorkspaceSelection()
  }

  private func applyWorkspaceCreateEntryPoint(_ entryPoint: WorkspaceCreateEntryPoint) {
    switch entryPoint {
    case .agent:
      viewModel.createMode = .terminal
    }
  }
}
