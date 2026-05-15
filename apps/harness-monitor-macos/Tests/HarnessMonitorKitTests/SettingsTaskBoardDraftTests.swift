import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Settings task-board draft")
struct SettingsTaskBoardDraftTests {
  @Test("Todoist token round trips through secure credentials snapshot")
  func todoistTokenRoundTripsThroughSnapshot() {
    let source = TaskBoardGitSettingsSnapshot(
      orchestratorSettings: TaskBoardOrchestratorSettings(policyVersion: "task-board-policy-v1"),
      runtimeConfig: TaskBoardGitRuntimeConfig(),
      githubCredentials: TaskBoardGitHubCredentialSnapshot(globalToken: "ghu_global"),
      todoistCredentials: TaskBoardTodoistCredentialSnapshot(token: "todoist-token")
    )

    var draft = TaskBoardGitSettingsDraft(snapshot: source)
    draft.todoistToken = " next-todoist-token "

    let snapshot = draft.snapshot

    #expect(snapshot.githubCredentials.globalToken == "ghu_global")
    #expect(snapshot.todoistCredentials.token == "next-todoist-token")
    #expect(snapshot.todoistCredentials.syncRequest.token == "next-todoist-token")
  }

  @Test("Blank Todoist token clears secure credential")
  func blankTodoistTokenClearsCredential() {
    var draft = TaskBoardGitSettingsDraft()
    draft.todoistToken = "   "

    #expect(draft.snapshot.todoistCredentials.token == nil)
    #expect(draft.snapshot.todoistCredentials.isEmpty)
  }
}
