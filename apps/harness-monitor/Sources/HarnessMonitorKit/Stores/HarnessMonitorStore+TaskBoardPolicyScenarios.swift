import Foundation

extension HarnessMonitorStore {
  /// Add a confidence scenario to the active workspace. The daemon persists it on
  /// `scenarios_json` and replies with the post-mutation workspace snapshot, which
  /// lands the new scenario set through `syncTaskBoardPolicyCanvasWorkspace`. The
  /// scenario set drives simulation, not the active canvas document, so the active
  /// canvas is not force-reloaded here; the confidence panel re-runs the matrix.
  @discardableResult
  public func createTaskBoardPolicyScenario(name: String, input: PolicyInput) async -> Bool {
    await mutateTaskBoardPolicyScenarios(successMessage: "Added scenario") { client in
      try await client.createTaskBoardPolicyScenario(
        request: TaskBoardPolicyScenarioCreateRequest(name: name, input: input)
      )
    }
  }

  /// Replace an existing scenario's name and input by id.
  @discardableResult
  public func updateTaskBoardPolicyScenario(
    id: String,
    name: String,
    input: PolicyInput
  ) async -> Bool {
    await mutateTaskBoardPolicyScenarios(successMessage: "Updated scenario") { client in
      try await client.updateTaskBoardPolicyScenario(
        request: TaskBoardPolicyScenarioUpdateRequest(id: id, name: name, input: input)
      )
    }
  }

  /// Remove a scenario by id.
  @discardableResult
  public func deleteTaskBoardPolicyScenario(id: String) async -> Bool {
    await mutateTaskBoardPolicyScenarios(successMessage: "Deleted scenario") { client in
      try await client.deleteTaskBoardPolicyScenario(
        request: TaskBoardPolicyScenarioDeleteRequest(id: id)
      )
    }
  }

  /// Restore the default seeded scenario set, discarding edits and deletions.
  @discardableResult
  public func resetTaskBoardPolicyScenarios() async -> Bool {
    await mutateTaskBoardPolicyScenarios(successMessage: "Reset scenarios") { client in
      try await client.resetTaskBoardPolicyScenarios(
        request: TaskBoardPolicyScenarioResetRequest()
      )
    }
  }

  private func mutateTaskBoardPolicyScenarios(
    successMessage: String,
    perform: (any HarnessMonitorClientProtocol) async throws -> TaskBoardPolicyCanvasWorkspace
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let workspace = try await perform(client)
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: false
      )
      presentSuccessFeedback(successMessage)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
