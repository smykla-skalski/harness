import Foundation

// Wire maps for the orchestrator token-sync response bodies (GitHub/Todoist/OpenRouter). Thin
// mirrors; the GitHub repository count narrows UInt -> Int.

extension TaskBoardGitHubTokensSyncResponse {
  init(wire: TaskBoardGitHubTokensSyncResponseWire) {
    self.init(
      globalTokenConfigured: wire.globalTokenConfigured,
      repositoryTokenCount: Int(wire.repositoryTokenCount)
    )
  }
}

extension TaskBoardTodoistTokenSyncResponse {
  init(wire: TaskBoardTodoistTokenSyncResponseWire) {
    self.init(tokenConfigured: wire.tokenConfigured)
  }
}

extension TaskBoardOpenRouterTokenSyncResponse {
  init(wire: TaskBoardOpenRouterTokenSyncResponseWire) {
    self.init(tokenConfigured: wire.tokenConfigured)
  }
}
