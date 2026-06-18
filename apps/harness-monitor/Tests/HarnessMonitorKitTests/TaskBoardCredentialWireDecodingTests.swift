import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the orchestrator token-sync response bodies. Generated from
/// runtime_config.rs; the maps narrow the GitHub repository count UInt -> Int.
@Suite("Task board credential wire decoding")
struct TaskBoardCredentialWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("github tokens response maps the flag and narrows the count")
  func githubTokensResponse() throws {
    let data = try #require(
      #"{"global_token_configured": true, "repository_token_count": 3}"#.data(using: .utf8)
    )
    let wire = try decoder.decode(TaskBoardGitHubTokensSyncResponseWire.self, from: data)
    let response = TaskBoardGitHubTokensSyncResponse(wire: wire)
    #expect(response.globalTokenConfigured == true)
    #expect(response.repositoryTokenCount == 3)
  }

  @Test("todoist and openrouter responses map the configured flag")
  func tokenConfiguredResponses() throws {
    let todoistData = try #require(#"{"token_configured": true}"#.data(using: .utf8))
    let todoist = TaskBoardTodoistTokenSyncResponse(
      wire: try decoder.decode(TaskBoardTodoistTokenSyncResponseWire.self, from: todoistData)
    )
    #expect(todoist.tokenConfigured == true)

    let openRouterData = try #require(#"{"token_configured": false}"#.data(using: .utf8))
    let openRouter = TaskBoardOpenRouterTokenSyncResponse(
      wire: try decoder.decode(TaskBoardOpenRouterTokenSyncResponseWire.self, from: openRouterData)
    )
    #expect(openRouter.tokenConfigured == false)
  }
}
