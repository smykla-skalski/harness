import Foundation
import HarnessMonitorPolicyModels

@testable import HarnessMonitorKit

// Scenario CRUD mock overrides. The recording client keeps the scenario set inline
// on the stored workspace; the daemon's seeding/persistence is covered by the Rust
// Phase-4 tests, so reset here just restores the mock baseline (no scenarios).
extension RecordingHarnessClient {
  func createPolicyScenario(
    request: PolicyScenarioCreateRequest
  ) async throws -> PolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      let id = "scenario-\(workspace.scenarios.count + 1)"
      workspace.scenarios.append(
        PolicyScenario(id: id, name: request.name, input: request.input, seeded: false)
      )
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func updatePolicyScenario(
    request: PolicyScenarioUpdateRequest
  ) async throws -> PolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      if let index = workspace.scenarios.firstIndex(where: { $0.id == request.id }) {
        workspace.scenarios[index].name = request.name
        workspace.scenarios[index].input = request.input
      }
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func deletePolicyScenario(
    request: PolicyScenarioDeleteRequest
  ) async throws -> PolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      workspace.scenarios.removeAll { $0.id == request.id }
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }

  func resetPolicyScenarios(
    request _: PolicyScenarioResetRequest
  ) async throws -> PolicyCanvasWorkspace {
    lock.withLock {
      var workspace = ensurePolicyWorkspaceStateLocked()
      workspace.scenarios = []
      policyCanvasWorkspaceStorage = workspace
      return workspace
    }
  }
}
