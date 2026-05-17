import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasView {
  var dashboardSnapshot: DashboardCanvasSnapshot {
    DashboardCanvasSnapshot(
      document: dashboardUI?.taskBoardPolicyPipeline,
      simulation: dashboardUI?.taskBoardPolicySimulation,
      audit: dashboardUI?.taskBoardPolicyAudit
    )
  }

  var remoteActionsEnabled: Bool {
    allowsRemoteActions && store != nil
  }

  var remoteActionDisabledReason: String {
    if !allowsRemoteActions {
      return Self.labRemoteActionDisabledReason
    }
    return Self.missingStoreRemoteActionDisabledReason
  }

  var simulationOverlayAvailable: Bool {
    viewModel.latestSimulation != nil
  }

  var simulationOverlayResolved: Bool {
    guard simulationOverlayAvailable else {
      return false
    }
    if let override = simulationOverlayOverride {
      return override
    }
    return viewModel.selectedTab == .simulation
  }

  func toggleSimulationOverlay() {
    simulationOverlayOverride = !simulationOverlayResolved
  }

  func bindStatusLine() {
    viewModel.statusCallback = { @MainActor newStatus in
      statusLine = newStatus
    }
  }

  func bindAutosaveTrigger() {
    if suppressesAutosave || !remoteActionsEnabled {
      viewModel.cancelAutosave()
      viewModel.autosaveTrigger = nil
      return
    }
    viewModel.autosaveTrigger = { @MainActor in
      viewModel.scheduleAutosave {
        performSave(reason: .autosave)
      }
    }
  }
}
