import HarnessMonitorKit
import SwiftUI

enum WorkspacePreviewCreatePreset: String, Sendable {
  static let environmentKey = "HARNESS_MONITOR_PREVIEW_WORKSPACE_CREATE_PRESET"

  case acpLeaderCopilot = "acp-leader-copilot"

  init?(environment: [String: String]) {
    let rawValue = environment[Self.environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard let rawValue, !rawValue.isEmpty else {
      return nil
    }
    self.init(rawValue: rawValue)
  }
}

extension WorkspaceWindowView {
  @discardableResult
  func consumePendingWorkspaceSelection() -> Bool {
    guard let pending = store.consumePendingWorkspaceSelectionRequest() else {
      return false
    }
    if case .create = pending.selection, let createEntryPoint = pending.createEntryPoint {
      applyWorkspaceCreateEntryPoint(
        createEntryPoint,
        createSessionID: pending.createSessionID
      )
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
    createSessionID: String? = nil,
    to viewModel: ViewModel
  ) {
    let normalizedCreateSessionID = normalizedCreateSessionAnchor(createSessionID)
    switch entryPoint {
    case .agent:
      viewModel.createMode = .terminal
    }
    viewModel.pendingCreateSessionID = normalizedCreateSessionID
    if let normalizedCreateSessionID {
      viewModel.createSessionID = normalizedCreateSessionID
    }
  }

  static func normalizedCreateSessionAnchor(_ sessionID: String?) -> String? {
    guard let sessionID else {
      return nil
    }
    let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func resolvedCreateSessionAnchor(
    selection: WorkspaceSelection,
    createSessionID: String?,
    selectedSessionID: String?,
    sessionSummary: (String) -> SessionSummary?
  ) -> String? {
    if let selectedSessionID = normalizedCreateSessionAnchor(selectedSessionID) {
      return selectedSessionID
    }
    let selectionSessionID = knownCreateSessionAnchor(
      selection.sessionID,
      sessionSummary: sessionSummary
    )
    let createSessionID = knownCreateSessionAnchor(
      createSessionID,
      sessionSummary: sessionSummary
    )
    return createSessionID ?? selectionSessionID
  }

  static func knownCreateSessionAnchor(
    _ sessionID: String?,
    sessionSummary: (String) -> SessionSummary?
  ) -> String? {
    guard let sessionID = normalizedCreateSessionAnchor(sessionID),
      sessionSummary(sessionID) != nil
    else {
      return nil
    }
    return sessionID
  }

  func knownCreateSessionAnchor(_ sessionID: String?) -> String? {
    Self.knownCreateSessionAnchor(sessionID) { store.sessionIndex.sessionSummary(for: $0) }
  }

  private func applyWorkspaceCreateEntryPoint(
    _ entryPoint: WorkspaceCreateEntryPoint,
    createSessionID: String? = nil
  ) {
    Self.applyWorkspaceCreateEntryPoint(
      entryPoint,
      createSessionID: createSessionID,
      to: viewModel
    )
  }

  static func previewCreatePreset(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> WorkspacePreviewCreatePreset? {
    WorkspacePreviewCreatePreset(environment: environment)
  }

  static func shouldRestoreSavedLaunchPreset(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    previewCreatePreset(environment: environment) == nil
  }

  static func applyPreviewCreatePresetIfNeeded(
    to viewModel: ViewModel,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    guard case .create = viewModel.selection,
      let preset = previewCreatePreset(environment: environment)
    else {
      return
    }
    applyPreviewCreatePreset(preset, to: viewModel)
  }

  static func applyPreviewCreatePreset(
    _ preset: WorkspacePreviewCreatePreset,
    to viewModel: ViewModel
  ) {
    switch preset {
    case .acpLeaderCopilot:
      viewModel.createMode = .terminal
      viewModel.selectedLaunchSelection = .acp("copilot")
      viewModel.runtime = .copilot
      viewModel.selectedRole = .leader
      viewModel.selectedAcpFallbackRole = .observer
    }
  }
}
