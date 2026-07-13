import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board GitHub URL")
struct TaskBoardGitHubURLTests {
  @Test("GitHub source URL takes precedence over workflow pull request URL")
  func githubSourceURLTakesPrecedence() {
    let sourceURL = "https://github.com/example/project/issues/42"
    let item = taskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#42",
          url: sourceURL
        )
      ],
      workflow: TaskBoardWorkflowState(
        prUrl: "https://github.com/example/project/pull/7"
      )
    )

    #expect(item.taskBoardGitHubURL?.absoluteString == sourceURL)
  }

  @Test("Workflow pull request URL is used when no valid source URL exists")
  func workflowPullRequestURLIsFallback() {
    let pullRequestURL = "https://www.github.com/example/project/pull/7"
    let item = taskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#42",
          url: "https://code.example.com/example/project/issues/42"
        )
      ],
      workflow: TaskBoardWorkflowState(prUrl: "  \(pullRequestURL)\n")
    )

    #expect(item.taskBoardGitHubURL?.absoluteString == pullRequestURL)
  }

  @Test("Non-secure, lookalike, and mismatched provider URLs are rejected")
  func invalidGitHubURLsAreRejected() {
    let item = taskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#1",
          url: "http://github.com/example/project/issues/1"
        ),
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#2",
          url: "https://github.com.example/project/issues/2"
        ),
        TaskBoardExternalRef(
          provider: .todoist,
          externalId: "external-3",
          url: "https://github.com/example/project/issues/3"
        ),
      ],
      workflow: TaskBoardWorkflowState(prUrl: "file://github.com/example/project/pull/4")
    )

    #expect(item.taskBoardGitHubURL == nil)
  }

  @Test("Repository owner accepts a padded workflow pull request URL")
  func repositoryOwnerAcceptsPaddedWorkflowURL() {
    let item = taskBoardItem(
      externalRefs: [],
      workflow: TaskBoardWorkflowState(
        prUrl: "  https://github.com/example/project/pull/7\n"
      ),
      projectId: nil
    )

    #expect(item.taskBoardRepositoryOwner == "example")
  }

  private func taskBoardItem(
    externalRefs: [TaskBoardExternalRef],
    workflow: TaskBoardWorkflowState?,
    projectId: String? = "example/project"
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-item",
      title: "Board item",
      body: "Body",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: projectId,
      agentMode: .interactive,
      externalRefs: externalRefs,
      planning: TaskBoardPlanningState(),
      workflow: workflow,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-13T10:00:00Z",
      updatedAt: "2026-07-13T10:01:00Z",
      deletedAt: nil
    )
  }
}
