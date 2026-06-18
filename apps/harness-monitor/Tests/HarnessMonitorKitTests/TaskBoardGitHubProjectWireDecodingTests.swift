import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the GitHubProjectConfig sub-tree (nested in the orchestrator
/// settings). Generated from github/config.rs; checkout_path exercises the new PathBuf -> String
/// generator arm, and merge_method/enabled_automations ride bare through the decoder-agnostic
/// TaskBoardGitHubMergeMethod/TaskBoardGitHubAutomation hand enums.
@Suite("Task board github project wire decoding")
struct TaskBoardGitHubProjectWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("github project config maps the whole tree including the path and bare enums")
  func githubProjectConfigMapping() throws {
    let payload = #"""
      {
        "owner": "acme", "repo": "widget", "checkout_path": "/checkouts/widget",
        "default_branch": "main", "branch_prefix": "c/", "merge_method": "rebase",
        "labels": {"managed": "m", "auto_merge": "am", "needs_human": "nh", "protected_path": "pp"},
        "protected_paths": [{"pattern": "src/**"}],
        "requested_reviewers": {"reviewers": ["r1"], "team_reviewers": ["t1"]},
        "enabled_automations": {"enabled": ["sync_task_board", "create_branch"]}
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(GitHubProjectConfigWire.self, from: data)
    let config = TaskBoardGitHubProjectConfig(wire: wire)

    #expect(config.owner == "acme")
    #expect(config.checkoutPath == "/checkouts/widget")
    #expect(config.mergeMethod == .rebase)
    #expect(config.labels.managed == "m")
    #expect(config.labels.autoMerge == "am")
    #expect(config.protectedPaths.map(\.pattern) == ["src/**"])
    #expect(config.requestedReviewers.reviewers == ["r1"])
    #expect(config.requestedReviewers.teamReviewers == ["t1"])
    #expect(config.enabledAutomations.enabled == [.syncTaskBoard, .createBranch])
  }
}
