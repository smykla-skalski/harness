import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board settings path materialization")
struct HarnessMonitorStoreTaskBoardMaterializerTests {
  @Test("Unchanged loaded project directory does not require a new bookmark")
  func unchangedLoadedProjectDirectoryDoesNotRequireNewBookmark() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let snapshot = settingsSnapshot(projectDir: "/Users/example/Projects/harness")
    let baseline = TaskBoardGitSettingsPathBaseline(snapshot: snapshot)
    let initialBookmarkCount = await store.bookmarkStore?.all().count

    let materialized = try await store.materializeTaskBoardGitSettings(
      snapshot,
      preservingPathsFrom: baseline
    )

    #expect(materialized.orchestratorSettings.projectDir == "/Users/example/Projects/harness")
    #expect(await store.bookmarkStore?.all().count == initialBookmarkCount)
  }

  private func settingsSnapshot(projectDir: String) -> TaskBoardGitSettingsSnapshot {
    TaskBoardGitSettingsSnapshot(
      orchestratorSettings: TaskBoardOrchestratorSettings(
        enabledWorkflows: [.defaultTask],
        dryRunDefault: true,
        projectDir: projectDir,
        policyVersion: "task-board-policy-v1"
      ),
      runtimeConfig: TaskBoardGitRuntimeConfig(),
      githubCredentials: TaskBoardGitHubCredentialSnapshot()
    )
  }
}
