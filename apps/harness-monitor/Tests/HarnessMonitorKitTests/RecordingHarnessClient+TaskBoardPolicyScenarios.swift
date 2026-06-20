import Foundation
import HarnessMonitorPolicyModels

@testable import HarnessMonitorKit

// Scenario CRUD mock overrides. The recording client keeps the scenario set inline
// on the stored workspace; the daemon's seeding/persistence is covered by the Rust
// Phase-4 tests, so reset here just restores the mock baseline (no scenarios).
extension RecordingHarnessClient {
  func createTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      let id = "scenario-\(workspace.scenarios.count + 1)"
      workspace.scenarios.append(
        PolicyScenario(id: id, name: request.name, input: request.input, seeded: false)
      )
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func updateTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioUpdateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      if let index = workspace.scenarios.firstIndex(where: { $0.id == request.id }) {
        workspace.scenarios[index].name = request.name
        workspace.scenarios[index].input = request.input
      }
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func deleteTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      workspace.scenarios.removeAll { $0.id == request.id }
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func resetTaskBoardPolicyScenarios(
    request _: TaskBoardPolicyScenarioResetRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensureTaskBoardPolicyWorkspaceStateLocked()
      workspace.scenarios = []
      taskBoardPolicyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }
}
