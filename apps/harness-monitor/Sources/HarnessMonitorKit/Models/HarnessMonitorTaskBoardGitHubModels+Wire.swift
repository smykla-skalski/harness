import Foundation

// Wire maps for the GitHubProjectConfig sub-tree (nested in the orchestrator settings). Thin
// mirrors; mergeMethod (TaskBoardGitHubMergeMethod) and the enabled automations
// (TaskBoardGitHubAutomation) are decoder-agnostic hand enums that ride through bare, and
// checkout_path is the PathBuf the generator now maps to String.

extension TaskBoardProtectedPathRule {
  init(wire: ProtectedPathRuleWire) {
    self.init(pattern: wire.pattern)
  }
}

extension TaskBoardGitHubAutomationLabels {
  init(wire: GitHubAutomationLabelsWire) {
    self.init(
      managed: wire.managed,
      autoMerge: wire.autoMerge,
      needsHuman: wire.needsHuman,
      protectedPath: wire.protectedPath
    )
  }
}

extension TaskBoardGitHubRequestedReviewers {
  init(wire: GitHubRequestedReviewersWire) {
    self.init(reviewers: wire.reviewers, teamReviewers: wire.teamReviewers)
  }
}

extension TaskBoardGitHubAutomationToggles {
  init(wire: GitHubAutomationTogglesWire) {
    self.init(enabled: wire.enabled)
  }
}

extension TaskBoardGitHubProjectConfig {
  init(wire: GitHubProjectConfigWire) {
    self.init(
      owner: wire.owner,
      repo: wire.repo,
      checkoutPath: wire.checkoutPath,
      defaultBranch: wire.defaultBranch,
      branchPrefix: wire.branchPrefix,
      mergeMethod: wire.mergeMethod,
      labels: TaskBoardGitHubAutomationLabels(wire: wire.labels),
      protectedPaths: wire.protectedPaths.map(TaskBoardProtectedPathRule.init(wire:)),
      requestedReviewers: TaskBoardGitHubRequestedReviewers(wire: wire.requestedReviewers),
      enabledAutomations: TaskBoardGitHubAutomationToggles(wire: wire.enabledAutomations)
    )
  }
}
