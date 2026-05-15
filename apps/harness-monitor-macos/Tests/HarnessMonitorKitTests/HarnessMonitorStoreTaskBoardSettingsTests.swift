import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board settings save ordering")
struct HarnessMonitorStoreTaskBoardSettingsTests {
  @Test("Runtime config failure after orchestrator success surfaces partial save")
  func runtimeConfigFailureAfterOrchestratorSuccessSurfacesPartialSave() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardRuntimeConfigError(
      HarnessMonitorAPIError.server(code: 500, message: "Runtime config write failed.")
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCallCount = client.recordedCalls().count
    let snapshot = makeSettingsSnapshot()

    let success = await store.updateTaskBoardGitSettings(snapshot: snapshot)

    #expect(success == false)
    let newCalls = Array(client.recordedCalls().dropFirst(baselineCallCount))
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardOrchestratorSettings = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardGitRuntimeConfig = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardGitHubTokens = call { return true }
        return false
      } == false
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardTodoistToken = call { return true }
        return false
      } == false
    )
    let failureMessage = store.currentFailureFeedbackMessage ?? ""
    #expect(failureMessage.contains("Partial save"))
    #expect(failureMessage.contains("runtime config did not"))
  }

  @Test("Orchestrator failure bails before runtime config attempt")
  func orchestratorFailureBailsBeforeRuntimeConfig() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardOrchestratorSettingsError(
      HarnessMonitorAPIError.server(code: 502, message: "Orchestrator settings rejected.")
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCallCount = client.recordedCalls().count
    let snapshot = makeSettingsSnapshot()

    let success = await store.updateTaskBoardGitSettings(snapshot: snapshot)

    #expect(success == false)
    let newCalls = Array(client.recordedCalls().dropFirst(baselineCallCount))
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardOrchestratorSettings = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardGitRuntimeConfig = call { return true }
        return false
      } == false
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardGitHubTokens = call { return true }
        return false
      } == false
    )
  }

  @Test("Token sync failure runs after runtime success but leaves keychain unchanged")
  func tokenSyncFailureRunsAfterRuntimeSuccessButLeavesKeychainUnchanged() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardGitHubTokensSyncError(
      HarnessMonitorAPIError.server(code: 503, message: "Token sync unavailable.")
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCallCount = client.recordedCalls().count
    let snapshot = makeSettingsSnapshot()

    let success = await store.updateTaskBoardGitSettings(snapshot: snapshot)

    #expect(success == false)
    let newCalls = Array(client.recordedCalls().dropFirst(baselineCallCount))
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardOrchestratorSettings = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardGitRuntimeConfig = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardGitHubTokens = call { return true }
        return false
      }
    )
    let failureMessage = store.currentFailureFeedbackMessage ?? ""
    #expect(failureMessage.contains("Partial save"))
    #expect(failureMessage.contains("token sync did not"))
    #expect(failureMessage.contains("keychain left unchanged"))
  }

  private func makeSettingsSnapshot() -> TaskBoardGitSettingsSnapshot {
    TaskBoardGitSettingsSnapshot(
      orchestratorSettings: TaskBoardOrchestratorSettings(
        enabledWorkflows: [.defaultTask],
        dryRunDefault: true,
        dispatchStatusFilter: .todo,
        projectDir: nil,
        githubProject: TaskBoardGitHubProjectConfig(
          owner: "example",
          repo: "harness",
          checkoutPath: "",
          defaultBranch: "main",
          branchPrefix: "c/"
        ),
        githubInbox: TaskBoardGitHubInboxConfig(),
        policyVersion: "task-board-policy-v1"
      ),
      runtimeConfig: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(),
        repositoryOverrides: []
      ),
      githubCredentials: TaskBoardGitHubCredentialSnapshot(
        globalToken: "new-token",
        repositoryTokens: []
      ),
      todoistCredentials: TaskBoardTodoistCredentialSnapshot(token: nil)
    )
  }
}
