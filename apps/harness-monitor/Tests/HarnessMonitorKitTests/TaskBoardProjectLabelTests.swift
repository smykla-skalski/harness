import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board project labels")
struct TaskBoardProjectLabelTests {
  @Test("Unique repository names omit their owner")
  func uniqueRepositoryNamesOmitTheirOwner() {
    let resolver = TaskBoardProjectLabelResolver(
      projectIDs: ["alpha/widget", "beta/control-plane"]
    )

    #expect(resolver.label(for: "alpha/widget") == "widget")
    #expect(resolver.label(for: "beta/control-plane") == "control-plane")
  }

  @Test("Ambiguous repository names retain every owner")
  func ambiguousRepositoryNamesRetainEveryOwner() {
    let resolver = TaskBoardProjectLabelResolver(
      projectIDs: ["alpha/console", "beta/CONSOLE", "gamma/worker"]
    )

    #expect(resolver.label(for: "alpha/console") == "alpha/console")
    #expect(resolver.label(for: "beta/CONSOLE") == "beta/CONSOLE")
    #expect(resolver.label(for: "gamma/worker") == "worker")
  }

  @Test("Repeated cards from one repository remain unambiguous")
  func repeatedCardsFromOneRepositoryRemainUnambiguous() {
    let resolver = TaskBoardProjectLabelResolver(
      projectIDs: ["alpha/console", "alpha/console", "ALPHA/CONSOLE"]
    )

    #expect(resolver.label(for: "alpha/console") == "console")
    #expect(resolver.label(for: "ALPHA/CONSOLE") == "CONSOLE")
  }

  @Test("Non repository project identifiers remain unchanged")
  func nonRepositoryProjectIdentifiersRemainUnchanged() {
    let projectIDs = ["project-1", "owner/repo/extra", "/repo", "owner/"]
    let resolver = TaskBoardProjectLabelResolver(projectIDs: projectIDs)

    for projectID in projectIDs {
      #expect(resolver.label(for: projectID) == projectID)
    }
  }

  @Test("Full repository names can be forced")
  func fullRepositoryNamesCanBeForced() {
    let resolver = TaskBoardProjectLabelResolver(projectIDs: ["alpha/widget"])

    #expect(
      resolver.label(for: "alpha/widget", alwaysShowFullName: true) == "alpha/widget"
    )
  }

  @Test("A registered project names the card, not the value the item was imported with")
  func registeredProjectNamesTheCard() {
    let resolver = TaskBoardProjectLabelResolver(
      projects: [project(id: "project-a", slug: "alpha/widget")],
      projectIDs: []
    )

    #expect(resolver.label(for: item(sourceProjectId: "project-a")) == "widget")
  }

  @Test("A renamed project reads by its current slug while the item never moves")
  func renamedProjectReadsByItsCurrentSlug() {
    let item = item(sourceProjectId: "project-a", executionRepository: "alpha/widget")
    let renamed = TaskBoardProjectLabelResolver(
      projects: [project(id: "project-a", slug: "alpha/gadget")],
      projectIDs: []
    )

    #expect(renamed.label(for: item) == "gadget")
  }

  @Test("A display name is shown exactly as it was typed")
  func displayNameIsShownVerbatim() {
    let resolver = TaskBoardProjectLabelResolver(
      projects: [project(id: "project-a", slug: "alpha/widget", displayName: "Widget Factory")],
      projectIDs: []
    )

    #expect(resolver.label(for: item(sourceProjectId: "project-a")) == "Widget Factory")
    #expect(
      resolver.label(for: item(sourceProjectId: "project-a"), alwaysShowFullName: true)
        == "Widget Factory"
    )
  }

  @Test("An unregistered project falls back to the identity on the item")
  func unregisteredProjectFallsBackToTheItem() {
    let resolver = TaskBoardProjectLabelResolver(projects: [], projectIDs: ["alpha/widget"])

    #expect(
      resolver.label(
        for: item(sourceProjectId: "project-missing", executionRepository: "alpha/widget")
      ) == "widget"
    )
  }

  @Test("An item belonging to no project resolves to no label")
  func itemWithNoProjectResolvesToNoLabel() {
    let resolver = TaskBoardProjectLabelResolver(projects: [], projectIDs: [])

    #expect(resolver.label(for: item(sourceProjectId: nil)) == nil)
  }

  @Test("Registered slugs count toward repository name ambiguity")
  func registeredSlugsCountTowardAmbiguity() {
    let resolver = TaskBoardProjectLabelResolver(
      projects: [
        project(id: "project-a", slug: "alpha/console"),
        project(id: "project-b", slug: "beta/console"),
      ],
      projectIDs: []
    )

    #expect(resolver.label(for: item(sourceProjectId: "project-a")) == "alpha/console")
    #expect(resolver.label(for: item(sourceProjectId: "project-b")) == "beta/console")
  }

  /// The mark is only honest for a project the registry actually knows. An
  /// item pointing at nothing, or at a project missing from this catalog, has
  /// no color to show and must not be given one.
  @Test("Only a registered project carries a color")
  func onlyARegisteredProjectCarriesAColor() {
    let resolver = TaskBoardProjectLabelResolver(
      projects: [project(id: "project-a", slug: "alpha/console", color: .amber)],
      projectIDs: []
    )

    #expect(resolver.color(for: item(sourceProjectId: "project-a")) == .amber)
    #expect(resolver.color(for: item(sourceProjectId: nil)) == nil)
    #expect(
      resolver.color(
        for: item(sourceProjectId: nil, executionRepository: "alpha/console")
      ) == nil,
      "a repository the registry has not seen yet is named but not colored"
    )
    #expect(resolver.color(for: item(sourceProjectId: "project-unknown")) == nil)
  }

  private func project(
    id: String,
    slug: String,
    displayName: String? = nil,
    color: TaskBoardProjectColor = .blue
  ) -> TaskBoardProjectSummary {
    TaskBoardProjectSummary(
      projectId: id,
      source: .gitHub,
      slug: slug,
      displayName: displayName,
      color: color,
      itemCount: 0,
      readyCount: 0
    )
  }

  private func item(
    sourceProjectId: String?,
    executionRepository: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "label-item",
      title: "Task",
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: nil,
      sourceProjectId: sourceProjectId,
      executionRepository: executionRepository,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-24T10:00:00Z",
      updatedAt: "2026-07-24T10:01:00Z",
      deletedAt: nil
    )
  }
}
