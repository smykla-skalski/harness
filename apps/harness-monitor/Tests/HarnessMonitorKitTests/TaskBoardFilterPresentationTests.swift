import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board filtered presentation")
struct TaskBoardFilterPresentationTests {
  @Test("An active facet drops the cards it excludes, wherever their lane")
  func activeFacetDropsExcludedCards() async {
    var filters = TaskBoardFilterState()
    filters.togglePriority(.critical)

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [
          item(id: "urgent", status: .todo, priority: .critical),
          item(id: "routine", status: .todo, priority: .low),
          item(id: "urgent-running", status: .inProgress, priority: .critical),
        ],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [],
        filters: filters
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == ["urgent", "urgent-running"])
    #expect(presentation.apiItems(in: .todo).map(\.id) == ["urgent"])
    #expect(presentation.apiItems(in: .inProgress).map(\.id) == ["urgent-running"])
    #expect(presentation.hasBoardContent)
    #expect(presentation.hasUnfilteredContent)
  }

  @Test("A filter that hides the whole board reports why instead of reading as empty")
  func filterHidingTheBoardReportsWhy() async {
    var filters = TaskBoardFilterState()
    filters.toggleProject("kumahq/kuma")

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [item(id: "ready", status: .todo, projectId: "smykla-skalski/harness")],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [],
        filters: filters
      )
    )

    #expect(!presentation.hasBoardContent)
    #expect(presentation.hasUnfilteredContent)
    #expect(presentation.responsibleNarrowingCauses == [.facet(.project)])
  }

  @Test("A project facet is keyed on the identity, so a rename only moves the label")
  func projectFacetIsKeyedOnIdentity() async {
    let renamed = TaskBoardProjectSummary(
      projectId: "project-uuid",
      source: .gitHub,
      slug: "kumahq/kuma",
      displayName: "Kuma Mesh",
      itemCount: 1,
      readyCount: 1
    )
    var filters = TaskBoardFilterState()
    filters.toggleProject("project-uuid")

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [
          item(
            id: "ready",
            status: .todo,
            projectId: "kumahq/kuma",
            sourceProjectId: "project-uuid"
          )
        ],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [renamed],
        filters: filters
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == ["ready"])
    #expect(presentation.filterInventory.projects.map(\.id) == ["project-uuid"])
    #expect(presentation.filterInventory.projects.map(\.label) == ["Kuma Mesh"])
  }

  @Test("The source facet separates imported work from work created here")
  func sourceFacetSeparatesImportedWork() async {
    var filters = TaskBoardFilterState()
    filters.toggleSource(.gitHub)

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [
          item(id: "imported", status: .todo, importedFromProvider: .gitHub),
          item(id: "local", status: .todo),
        ],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [],
        filters: filters
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == ["imported"])
    #expect(
      presentation.filterInventory.sources.map(\.id).sorted() == ["github", "harness"]
    )
  }

  @Test("An unfiltered board carries a full inventory and blames nothing")
  func unfilteredBoardCarriesFullInventory() async {
    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [
          item(id: "ready", status: .todo, priority: .critical, tags: ["Backend", "backend "]),
          item(id: "running", status: .inProgress, priority: .low),
        ],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: []
      )
    )

    #expect(presentation.responsibleNarrowingCauses.isEmpty)
    #expect(presentation.filterInventory.priorities.map(\.id) == ["critical", "low"])
    // The two spellings of one tag collapse into a single option, and the one
    // card carrying both counts once towards it.
    #expect(presentation.filterInventory.tags.map(\.id) == ["backend"])
    #expect(presentation.filterInventory.tags.map(\.label) == ["Backend"])
    #expect(presentation.filterInventory.tags.map(\.count) == [1])
  }

  @Test("Search narrows the board wherever the card sits, and reports itself when it empties it")
  func searchNarrowsAcrossLanesAndReportsItself() async {
    let items = [
      item(id: "zone-sync", status: .todo, title: "Retry zone sync"),
      item(id: "zone-docs", status: .inReview, title: "Docs", body: "How a zone inherits"),
      item(id: "reconciler", status: .todo, title: "Split the reconciler"),
    ]
    let worker = TaskBoardOverviewPresentationWorker()

    let narrowed = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: items,
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [],
        searchText: "zone"
      )
    )

    #expect(narrowed.taskBoardItems.map(\.id) == ["zone-sync", "zone-docs"])
    #expect(narrowed.responsibleNarrowingCauses.isEmpty)
    // Suggestions are drawn before the search narrows anything, so the card
    // someone is still typing towards is in there.
    #expect(narrowed.searchCandidates.map(\.id) == items.map(\.id))

    let emptied = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: items,
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [],
        searchText: "ingress"
      )
    )

    #expect(!emptied.hasBoardContent)
    #expect(emptied.hasUnfilteredContent)
    #expect(emptied.responsibleNarrowingCauses == [.search])
  }

  private func item(
    id: String,
    status: TaskBoardStatus,
    title: String = "Board item",
    body: String = "Body",
    priority: TaskBoardPriority = .medium,
    tags: [String] = [],
    projectId: String? = nil,
    sourceProjectId: String? = nil,
    importedFromProvider: TaskBoardExternalRefProvider? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: body,
      status: status,
      priority: priority,
      tags: tags,
      projectId: projectId,
      sourceProjectId: sourceProjectId,
      agentMode: .interactive,
      externalRefs: [],
      importedFromProvider: importedFromProvider,
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-27T10:00:00Z",
      updatedAt: "2026-07-27T10:01:00Z",
      deletedAt: nil
    )
  }
}
