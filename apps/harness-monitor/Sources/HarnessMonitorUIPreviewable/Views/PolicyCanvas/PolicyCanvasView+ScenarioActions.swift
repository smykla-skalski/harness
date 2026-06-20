import HarnessMonitorKit
import HarnessMonitorPolicyModels

extension PolicyCanvasView {
  /// Open the editor on a blank scenario.
  func addScenario() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    scenarioEditRequest = PolicyCanvasScenarioEditRequest(
      scenarioId: nil,
      name: "",
      input: PolicyInput(action: .mergePr)
    )
  }

  /// Open the editor seeded from an existing scenario's full input, looked up on
  /// the workspace snapshot (the inspector rows only carry the verdict, not the
  /// input). Synthetic-id rows from a pre-scenario daemon have no workspace entry.
  func editScenario(id: String) {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    guard
      let scenario = runtime?.policyCanvasSnapshot.workspace?.scenarios
        .first(where: { $0.id == id })
    else {
      statusLine = "Scenario unavailable for editing"
      return
    }
    scenarioEditRequest = PolicyCanvasScenarioEditRequest(
      scenarioId: scenario.id,
      name: scenario.name,
      input: scenario.input
    )
  }

  /// Create or update the scenario from the editor, then re-evaluate.
  func confirmScenarioEdit(
    request: PolicyCanvasScenarioEditRequest,
    name: String,
    input: PolicyInput
  ) {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    Task { @MainActor in
      let succeeded: Bool
      if let scenarioId = request.scenarioId {
        succeeded =
          await runtime?.updatePolicyScenario(id: scenarioId, name: name, input: input) ?? false
      } else {
        succeeded = await runtime?.createPolicyScenario(name: name, input: input) ?? false
      }
      guard succeeded else {
        statusLine =
          request.scenarioId == nil ? "Could not add scenario" : "Could not update scenario"
        return
      }
      await reloadAfterScenarioChange()
    }
  }

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
