import HarnessMonitorKit

extension PolicyCanvasView {
  /// Drop a scenario, then re-evaluate. Routed from the confidence panel's
  /// inspector. Remote-action gated like the other canvas mutations.
  func deleteScenario(id: String) {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    Task { @MainActor in
      guard await runtime?.deletePolicyScenario(id: id) == true else {
        statusLine = "Could not delete scenario"
        return
      }
      await reloadAfterScenarioChange()
    }
  }

  /// Restore the seeded scenario set, then re-evaluate.
  func resetScenarios() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    Task { @MainActor in
      guard await runtime?.resetPolicyScenarios() == true else {
        statusLine = "Could not reset scenarios"
        return
      }
      await reloadAfterScenarioChange()
    }
  }

  /// Re-run the simulation over the now-current scenario set and refresh the
  /// pipeline so the decision matrix and scenario inspector reflect the change -
  /// the same simulate-then-reload the manual confidence run uses.
  private func reloadAfterScenarioChange() async {
    viewModel.isSimulating = true
    defer { viewModel.isSimulating = false }
    _ = await runtime?.simulatePolicyCanvas(document: viewModel.exportDocument())
    await forceReloadPolicyPipeline()
  }
}
