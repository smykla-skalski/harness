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
    HarnessMonitorAsyncWorkQueue.shared.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "Saving policy scenario") {
        let succeeded = await savePolicyScenario(request: request, name: name, input: input)
        guard succeeded else {
          await MainActor.run {
            statusLine =
              request.scenarioId == nil ? "Could not add scenario" : "Could not update scenario"
          }
          return
        }
        await reloadAfterScenarioChange()
      }
    )
  }

  /// Drop a scenario, then re-evaluate. Routed from the confidence panel's
  /// inspector. Remote-action gated like the other canvas mutations.
  func deleteScenario(id: String) {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "Deleting policy scenario") {
        guard await deletePolicyScenarioRuntime(id: id) else {
          await MainActor.run {
            statusLine = "Could not delete scenario"
          }
          return
        }
        await reloadAfterScenarioChange()
      }
    )
  }

  /// Restore the seeded scenario set, then re-evaluate.
  func resetScenarios() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "Resetting policy scenarios") {
        guard await resetPolicyScenariosRuntime() else {
          await MainActor.run {
            statusLine = "Could not reset scenarios"
          }
          return
        }
        await reloadAfterScenarioChange()
      }
    )
  }

  /// Re-run the simulation over the now-current scenario set and refresh the
  /// pipeline so the decision matrix and scenario inspector reflect the change -
  /// the same simulate-then-reload the manual confidence run uses.
  @MainActor
  private func savePolicyScenario(
    request: PolicyCanvasScenarioEditRequest,
    name: String,
    input: PolicyInput
  ) async -> Bool {
    if let scenarioId = request.scenarioId {
      return await runtime?.updatePolicyScenario(id: scenarioId, name: name, input: input) ?? false
    }
    return await runtime?.createPolicyScenario(name: name, input: input) ?? false
  }

  @MainActor
  private func deletePolicyScenarioRuntime(id: String) async -> Bool {
    await runtime?.deletePolicyScenario(id: id) == true
  }

  @MainActor
  private func resetPolicyScenariosRuntime() async -> Bool {
    await runtime?.resetPolicyScenarios() == true
  }

  @MainActor
  private func reloadAfterScenarioChange() async {
    viewModel.isSimulating = true
    defer { viewModel.isSimulating = false }
    _ = await runtime?.simulatePolicyCanvas(document: viewModel.exportDocument())
    await forceReloadPolicyPipeline()
  }
}
