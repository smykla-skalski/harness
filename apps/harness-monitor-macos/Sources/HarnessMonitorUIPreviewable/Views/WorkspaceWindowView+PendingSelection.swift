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
      resetDecisionFiltersToInitialState()
    }
    applyProgrammaticSelection(pending.selection, recordHistory: true)
    return true
  }

  func resolveInitialWorkspaceSelection() async {
    if consumePendingWorkspaceSelection() {
      await Task.yield()
      WorkspaceSelectionDefaults.write(viewModel.selection)
      return
    }
    await handleSelectionChange(from: .create, to: viewModel.selection)
    WorkspaceSelectionDefaults.write(viewModel.selection)
    updateNavigationState()
  }

  static func applyWorkspaceCreateEntryPoint(
    _ entryPoint: WorkspaceCreateEntryPoint,
    to viewModel: ViewModel
  ) {
    switch entryPoint {
    case .agent:
      viewModel.createMode = .terminal
    }
  }

  private func applyWorkspaceCreateEntryPoint(_ entryPoint: WorkspaceCreateEntryPoint) {
    Self.applyWorkspaceCreateEntryPoint(entryPoint, to: viewModel)
  }
}
