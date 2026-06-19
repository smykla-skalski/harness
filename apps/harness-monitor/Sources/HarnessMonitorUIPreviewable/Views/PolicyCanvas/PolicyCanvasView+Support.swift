import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasView {
  var dashboardSnapshot: DashboardCanvasSnapshot {
    if let dashboardSnapshotOverride {
      return dashboardSnapshotOverride
    }
    return runtime?.policyCanvasSnapshot
      ?? DashboardCanvasSnapshot(
        activeCanvasId: nil,
        document: nil,
        simulation: nil,
        audit: nil
      )
  }

  var remoteActionsEnabled: Bool {
    allowsRemoteActions && runtime != nil
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
    // Hidden by default once a simulation exists; the top-bar toggle is the
    // only thing that pins it on. The always-on confidence panel will later
    // replace this manual overlay.
    return simulationOverlayOverride ?? false
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

  /// Binds the debounced confidence auto-runner that replaced the Simulate
  /// button. Unbound (and any in-flight run cancelled) when remote actions are
  /// unavailable - the lab and the missing-store path have no daemon to run a
  /// simulation, exactly like `bindAutosaveTrigger`.
  func bindConfidenceTrigger() {
    guard remoteActionsEnabled else {
      viewModel.cancelConfidenceEvaluation()
      viewModel.confidenceTrigger = nil
      return
    }
    viewModel.confidenceTrigger = { @MainActor in
      viewModel.scheduleConfidenceEvaluation {
        simulate()
      }
    }
  }
}
