import Foundation

extension HarnessMonitorStore {
  /// Add a confidence scenario to the active workspace. The daemon persists it on
  /// `scenarios_json` and replies with the post-mutation workspace snapshot, which
  /// lands the new scenario set through `syncPolicyCanvasWorkspace`. The
  /// scenario set drives simulation, not the active canvas document, so the active
  /// canvas is not force-reloaded here; the confidence panel re-runs the matrix.
  @discardableResult
  public func createPolicyScenario(name: String, input: PolicyInput) async -> Bool {
    await mutatePolicyScenarios(successMessage: "Added scenario") { client in
      try await client.createPolicyScenario(
        request: PolicyScenarioCreateRequest(name: name, input: input)
      )
    }
  }

  /// Replace an existing scenario's name and input by id.
  @discardableResult
  public func updatePolicyScenario(
    id: String,
    name: String,
    input: PolicyInput
  ) async -> Bool {
    await mutatePolicyScenarios(successMessage: "Updated scenario") { client in
      try await client.updatePolicyScenario(
        request: PolicyScenarioUpdateRequest(id: id, name: name, input: input)
      )
    }
  }

  /// Remove a scenario by id.
  @discardableResult
  public func deletePolicyScenario(id: String) async -> Bool {
    await mutatePolicyScenarios(successMessage: "Deleted scenario") { client in
      try await client.deletePolicyScenario(
        request: PolicyScenarioDeleteRequest(id: id)
      )
    }
  }

  /// Restore the default seeded scenario set, discarding edits and deletions.
  @discardableResult
  public func resetPolicyScenarios() async -> Bool {
    await mutatePolicyScenarios(successMessage: "Reset scenarios") { client in
      try await client.resetPolicyScenarios(
        request: PolicyScenarioResetRequest()
      )
    }
  }

  private func mutatePolicyScenarios(
    successMessage: String,
    perform: (any HarnessMonitorClientProtocol) async throws -> PolicyCanvasWorkspace
  ) async -> Bool {
    await withSerializedTaskBoardPolicyPublication {
      await mutatePolicyScenariosSerialized(
        successMessage: successMessage,
        perform: perform
      )
    }
  }

  private func mutatePolicyScenariosSerialized(
    successMessage: String,
    perform: (any HarnessMonitorClientProtocol) async throws -> PolicyCanvasWorkspace
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else { return false }
    let client = access.client
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await perform(client)
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      guard
        await syncPolicyCanvasWorkspace(
          workspace,
          using: client,
          forceReloadActiveCanvas: false,
          taskBoardAccess: access
        )
      else { return false }
      try requireCurrentTaskBoardClientAccess(access)
      presentSuccessFeedback(successMessage)
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return false }
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
