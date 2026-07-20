import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board repository identity")
struct TaskBoardRepositoryIdentityTests {
  @Test("Board project wins when it is set")
  func boardProjectWinsWhenSet() {
    let item = item(projectId: "alpha/widget", executionRepository: "beta/other")

    #expect(item.taskBoardRepositoryIdentity == "alpha/widget")
  }

  @Test("GitHub imports fall back to the execution repository when project is empty")
  func executionRepositoryFallsBackWhenProjectEmpty() {
    let item = item(projectId: nil, executionRepository: "kong/kong-mesh")

    #expect(item.taskBoardRepositoryIdentity == "kong/kong-mesh")
  }

  @Test("A blank project string does not shadow the execution repository")
  func blankProjectDoesNotShadowExecutionRepository() {
    let item = item(projectId: "", executionRepository: "kong/kong-mesh")

    #expect(item.taskBoardRepositoryIdentity == "kong/kong-mesh")
  }

  @Test("The GitHub external ref supplies the repo when project and execution are empty")
  func externalRefSuppliesRepositoryWhenOthersEmpty() {
    let item = item(
      projectId: nil,
      executionRepository: nil,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "Kong/kong-mesh#10165",
          url: "https://github.com/Kong/kong-mesh/pull/10165"
        )
      ]
    )

    #expect(item.taskBoardRepositoryIdentity == "Kong/kong-mesh")
  }

  @Test("An item with no repository identity resolves to nil")
  func noRepositoryIdentityResolvesToNil() {
    let item = item(projectId: nil, executionRepository: nil)

    #expect(item.taskBoardRepositoryIdentity == nil)
  }

  @Test("The card labels a project-less GitHub import by its execution repository, not the mode")
  func cardLabelsExecutionRepositoryRatherThanAgentMode() async throws {
    let worker = TaskBoardOverviewPresentationWorker()
    let review = item(
      id: "review-item",
      projectId: nil,
      executionRepository: "kong/kong-mesh",
      importedFromProvider: .gitHub,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "Kong/kong-mesh#10165",
          url: "https://github.com/Kong/kong-mesh/pull/10165"
        )
      ]
    )

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [review],
        decisionItems: [],
        scopeSessionID: nil
      )
    )

    let card = try #require(presentation.apiCardPresentations(in: .todo)["review-item"])

    #expect(card.repositoryLabelDefault == "kong-mesh")
    #expect(card.repositoryLabelFullName == "kong/kong-mesh")
    #expect(review.agentMode == .headless)
  }

  private func item(
    id: String = "identity-item",
    projectId: String?,
    executionRepository: String?,
    importedFromProvider: TaskBoardExternalRefProvider? = nil,
    externalRefs: [TaskBoardExternalRef] = []
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "chore(deps): bump actions/setup-node from 6.4.0 to 6.5.0",
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: projectId,
      executionRepository: executionRepository,
      agentMode: .headless,
      externalRefs: externalRefs,
      importedFromProvider: importedFromProvider,
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-20T10:00:00Z",
      updatedAt: "2026-07-20T10:01:00Z",
      deletedAt: nil
    )
  }
}
