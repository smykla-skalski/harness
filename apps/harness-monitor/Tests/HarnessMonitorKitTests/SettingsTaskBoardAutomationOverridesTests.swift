import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Settings repository automation overrides")
struct SettingsTaskBoardAutomationOverridesTests {
  private static func draft(
    repositories: [TaskBoardRepositoryAutomationConfig] = [],
    reviewers: [String] = ["global-reviewer"]
  ) -> TaskBoardGitSettingsDraft {
    var draft = TaskBoardGitSettingsDraft(
      snapshot: TaskBoardGitSettingsSnapshot(
        orchestratorSettings: TaskBoardOrchestratorSettings(
          githubProject: TaskBoardGitHubProjectConfig(
            requestedReviewers: TaskBoardGitHubRequestedReviewers(reviewers: reviewers)
          ),
          repositories: repositories,
          policyVersion: "task-board-policy-v1"
        ),
        runtimeConfig: TaskBoardGitRuntimeConfig(),
        githubCredentials: TaskBoardGitHubCredentialSnapshot()
      )
    )
    // The draft edits reviewers as text, so seed the text the same way the
    // settings pane does before asking what a repository inherits.
    draft.requestedReviewersText = reviewers.joined(separator: "\n")
    return draft
  }

  @Test("Repository configs the pane never touches survive a save")
  func untouchedRepositoryConfigsRoundTrip() {
    let configured = TaskBoardRepositoryAutomationConfig(
      repository: "kumahq/kuma",
      preferredHostId: "mac-studio"
    )
    let draft = Self.draft(repositories: [configured])

    #expect(draft.snapshot.orchestratorSettings.repositories == [configured])
  }

  @Test("Overriding a group seeds it from the value the repository inherits")
  func overridingSeedsFromInheritedValue() {
    var draft = Self.draft()

    draft.beginOverriding(.requestedReviewers, for: "kumahq/kuma")

    #expect(draft.overrides(.requestedReviewers, for: "kumahq/kuma"))
    #expect(draft.requestedReviewers(for: "kumahq/kuma").reviewers == ["global-reviewer"])
  }

  @Test("Reverting the last override drops the repository entry")
  func revertingLastOverrideDropsEntry() {
    var draft = Self.draft()
    draft.beginOverriding(.labels, for: "kumahq/kuma")
    #expect(draft.automationConfig(for: "kumahq/kuma") != nil)

    draft.stopOverriding(.labels, for: "kumahq/kuma")

    #expect(draft.automationConfig(for: "kumahq/kuma") == nil)
    #expect(draft.snapshot.orchestratorSettings.repositories.isEmpty)
  }

  @Test("Reverting an override keeps a repository configured for other reasons")
  func revertingKeepsOtherRepositoryConfiguration() {
    var draft = Self.draft(
      repositories: [
        TaskBoardRepositoryAutomationConfig(repository: "kumahq/kuma", preferredHostId: "mac-studio")
      ]
    )
    draft.beginOverriding(.labels, for: "kumahq/kuma")

    draft.stopOverriding(.labels, for: "kumahq/kuma")

    #expect(draft.automationConfig(for: "kumahq/kuma")?.preferredHostId == "mac-studio")
    #expect(draft.overriddenKinds(for: "kumahq/kuma").isEmpty)
  }

  @Test("Two repositories resolve to their own reviewers")
  func repositoriesResolveIndependently() {
    var draft = Self.draft()
    draft.setRequestedReviewers(
      GitHubRequestedReviewersWire(reviewers: ["work-reviewer"]),
      for: "kumahq/kuma"
    )

    #expect(draft.requestedReviewers(for: "kumahq/kuma").reviewers == ["work-reviewer"])
    #expect(draft.requestedReviewers(for: "smykla/personal").reviewers == ["global-reviewer"])
    #expect(draft.overriddenKinds(for: "smykla/personal").isEmpty)
  }

  @Test("An override matches its repository regardless of slug casing")
  func overridesMatchCaseInsensitively() {
    var draft = Self.draft(
      repositories: [
        TaskBoardRepositoryAutomationConfig(
          repository: "KumaHQ/Kuma",
          requestedReviewers: GitHubRequestedReviewersWire(reviewers: ["work-reviewer"])
        )
      ]
    )

    #expect(draft.requestedReviewers(for: "kumahq/kuma").reviewers == ["work-reviewer"])

    draft.stopOverriding(.requestedReviewers, for: "kumahq/kuma")

    #expect(draft.snapshot.orchestratorSettings.repositories.isEmpty)
  }
}
