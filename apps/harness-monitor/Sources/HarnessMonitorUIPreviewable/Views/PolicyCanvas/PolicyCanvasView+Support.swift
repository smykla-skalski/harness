import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasView {
  var dashboardSnapshot: DashboardCanvasSnapshot {
    DashboardCanvasSnapshot(
      activeCanvasId: dashboardUI?.taskBoardPolicyCanvasWorkspace?.activeCanvasId,
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
    return simulationResultsVisible && viewModel.selectedTab == .simulation
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
    let seconds = autosaveDebounceSeconds
    let autosaveOff = seconds == PolicyCanvasAutosaveDefaults.offSeconds
    if suppressesAutosave || !remoteActionsEnabled || autosaveOff {
      viewModel.cancelAutosave()
      viewModel.autosaveTrigger = nil
      return
    }
    // Live setting wins: thread the configured window into the view model so a
    // change in Settings > Policies > Canvas takes effect on the next dirty
    // edge without reopening the canvas.
    viewModel.autosaveDebounceMilliseconds =
      PolicyCanvasAutosaveDefaults.milliseconds(forSeconds: seconds)
    viewModel.autosaveTrigger = { @MainActor in
      viewModel.scheduleAutosave {
        performSave(reason: .autosave)
      }
    }
  }
}
