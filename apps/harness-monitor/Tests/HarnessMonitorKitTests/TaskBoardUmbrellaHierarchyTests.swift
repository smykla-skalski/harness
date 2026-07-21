import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board umbrella hierarchy")
struct TaskBoardUmbrellaHierarchyTests {
  @Test("Direct children resolve ordered by childOrder, ties broken by id")
  func childrenResolveOrderedByChildOrder() {
    let umbrella = makeTaskBoardItem(id: "umbrella-1", kind: .umbrella)
    let third = makeTaskBoardItem(id: "child-c", parentItemId: "umbrella-1", childOrder: 2)
    let first = makeTaskBoardItem(id: "child-a", parentItemId: "umbrella-1", childOrder: 0)
    let secondA = makeTaskBoardItem(id: "child-b1", parentItemId: "umbrella-1", childOrder: 1)
    let secondB = makeTaskBoardItem(id: "child-b2", parentItemId: "umbrella-1", childOrder: 1)
    let unrelated = makeTaskBoardItem(id: "other", parentItemId: "umbrella-2")

    let children = TaskBoardUmbrellaHierarchy.children(
      of: umbrella.id,
      in: [third, first, secondA, secondB, unrelated, umbrella]
    )

    #expect(children.map(\.id) == ["child-a", "child-b1", "child-b2", "child-c"])
  }

  @Test("Deleted children never appear in the resolved list")
  func deletedChildrenAreExcluded() {
    let live = makeTaskBoardItem(id: "child-live", parentItemId: "umbrella-1", childOrder: 0)
    let deleted = makeTaskBoardItem(
      id: "child-deleted", parentItemId: "umbrella-1", childOrder: 1,
      deletedAt: "2026-01-01T00:00:00Z"
    )

    let children = TaskBoardUmbrellaHierarchy.children(of: "umbrella-1", in: [live, deleted])

    #expect(children.map(\.id) == ["child-live"])
  }

  @Test("Children spread across projects and repositories are all reachable")
  func childrenSpanMultipleProjectsAndRepositories() {
    let inProjectA = makeTaskBoardItem(
      id: "child-project-a", projectId: "project-a", parentItemId: "umbrella-1", childOrder: 0
    )
    let inRepoB = makeTaskBoardItem(
      id: "child-repo-b", executionRepository: "org/repo-b",
      parentItemId: "umbrella-1", childOrder: 1
    )
    let inProjectC = makeTaskBoardItem(
      id: "child-project-c", projectId: "project-c", parentItemId: "umbrella-1", childOrder: 2
    )

    let children = TaskBoardUmbrellaHierarchy.children(
      of: "umbrella-1",
      in: [inProjectA, inRepoB, inProjectC]
    )

    #expect(children.map(\.id) == ["child-project-a", "child-repo-b", "child-project-c"])
  }

  @Test("A child resolves its parent by id")
  func parentResolvesFromParentItemId() {
    let umbrella = makeTaskBoardItem(id: "umbrella-1", kind: .umbrella)
    let child = makeTaskBoardItem(id: "child-1", parentItemId: "umbrella-1")

    let parent = TaskBoardUmbrellaHierarchy.parent(of: child, in: [umbrella, child])

    #expect(parent?.id == "umbrella-1")
  }

  @Test("An item with no parent reference resolves no backlink")
  func backlinkIsNoneWithoutParentReference() {
    let item = makeTaskBoardItem(id: "solo")

    let backlink = TaskBoardParentBacklink(item: item, loadedItems: [item])

    #expect(backlink == .none)
  }

  @Test("A resolvable parent reference resolves to the loaded parent item")
  func backlinkResolvesLoadedParent() {
    let umbrella = makeTaskBoardItem(id: "umbrella-1", kind: .umbrella)
    let child = makeTaskBoardItem(id: "child-1", parentItemId: "umbrella-1")

    let backlink = TaskBoardParentBacklink(item: child, loadedItems: [umbrella, child])

    #expect(backlink == .resolved(umbrella))
  }

  @Test("A parent reference outside the loaded set says so instead of resolving to nothing")
  func backlinkReportsOutsideCurrentViewWhenParentIsNotLoaded() {
    let child = makeTaskBoardItem(id: "child-1", parentItemId: "umbrella-missing")

    let backlink = TaskBoardParentBacklink(item: child, loadedItems: [child])

    #expect(backlink == .outsideCurrentView(parentItemId: "umbrella-missing"))
  }

  @Test("Children in a collapsed lane are reported hidden, not silently dropped")
  func hiddenChildrenReportedWhenLaneIsCollapsed() {
    let umbrella = makeTaskBoardItem(id: "umbrella-1", kind: .umbrella)
    let visibleChild = makeTaskBoardItem(
      id: "child-visible", status: .todo, parentItemId: "umbrella-1", childOrder: 0
    )
    let hiddenChild = makeTaskBoardItem(
      id: "child-hidden", status: .inProgress, parentItemId: "umbrella-1", childOrder: 1
    )

    let summary = TaskBoardUmbrellaChildrenSummary.summarizing(
      umbrella.id,
      in: [umbrella, visibleChild, hiddenChild],
      collapsedLanes: [.inProgress]
    )

    #expect(summary.visibleChildren.map(\.id) == ["child-visible"])
    #expect(summary.hiddenChildren.map(\.id) == ["child-hidden"])
    #expect(summary.hiddenCount == 1)
    #expect(summary.notShownMessage == "1 child not shown here")
  }

  @Test("No collapsed lanes means every loaded child is visible and no message is shown")
  func noHiddenChildrenWhenNoLaneIsCollapsed() {
    let child = makeTaskBoardItem(id: "child-1", status: .todo, parentItemId: "umbrella-1")

    let summary = TaskBoardUmbrellaChildrenSummary.summarizing(
      "umbrella-1", in: [child], collapsedLanes: []
    )

    #expect(summary.hiddenChildren.isEmpty)
    #expect(summary.notShownMessage == nil)
  }

  @Test("Multiple hidden children pluralize the not-shown message")
  func multipleHiddenChildrenPluralizeMessage() {
    let hiddenA = makeTaskBoardItem(id: "child-a", status: .inProgress, parentItemId: "umbrella-1")
    let hiddenB = makeTaskBoardItem(id: "child-b", status: .inProgress, parentItemId: "umbrella-1")

    let summary = TaskBoardUmbrellaChildrenSummary.summarizing(
      "umbrella-1", in: [hiddenA, hiddenB], collapsedLanes: [.inProgress]
    )

    #expect(summary.notShownMessage == "2 children not shown here")
  }

  @Test("Opening a cross-scope item resolves from the full pool, not the view's scoped items")
  @MainActor
  func selectedItemResolvesAcrossScopeEvenWhenViewItemsAreScoped() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    let umbrella = makeTaskBoardItem(id: "umbrella-1", kind: .umbrella)
    let crossScopeChild = makeTaskBoardItem(id: "child-other-session", parentItemId: "umbrella-1")
    store.globalTaskBoardItems = [umbrella, crossScopeChild]

    // A session-window embedding whose own item snapshot has not (yet) picked up
    // the cross-scope child - `currentPresentation` stays empty here too, since
    // its rebuild only runs through the view's live `.task(id:)` lifecycle.
    let view = TaskBoardOverviewView(
      snapshot: TaskBoardInboxSnapshot(),
      taskBoardItems: [umbrella],
      store: store,
      taskBoardSessionID: "session-a",
      actions: TaskBoardOverviewActions(store: store, scope: .session(sessionID: "session-a")),
      decisionItems: [],
      decisionsByID: [:]
    )

    view.selectionModelValue.selectedItemID = crossScopeChild.id

    #expect(view.selectedTaskBoardItem?.id == crossScopeChild.id)
  }

  @Test("A not-yet-hydrated store still falls through to the view's own items")
  @MainActor
  func selectedItemResolvesFromViewItemsWhenStoreIsNotYetHydrated() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    // Cold launch / not-yet-hydrated dashboard: the store exists but hasn't
    // populated its global pool yet, while this session-window embedding's
    // own independent snapshot fetch already has the item.
    store.globalTaskBoardItems = []
    let item = makeTaskBoardItem(id: "session-only-item")

    let view = TaskBoardOverviewView(
      snapshot: TaskBoardInboxSnapshot(),
      taskBoardItems: [item],
      store: store,
      taskBoardSessionID: "session-a",
      actions: TaskBoardOverviewActions(store: store, scope: .session(sessionID: "session-a")),
      decisionItems: [],
      decisionsByID: [:]
    )

    view.selectionModelValue.selectedItemID = item.id

    #expect(view.selectedTaskBoardItem?.id == item.id)
  }
}

extension TaskBoardUmbrellaHierarchyTests {
  private func makeTaskBoardItem(
    id: String,
    kind: TaskBoardItemKind = .task,
    status: TaskBoardStatus = .todo,
    projectId: String? = nil,
    executionRepository: String? = nil,
    parentItemId: String? = nil,
    childOrder: UInt32 = 0,
    deletedAt: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Item \(id)",
      body: "",
      status: status,
      priority: .medium,
      tags: [],
      projectId: projectId,
      executionRepository: executionRepository,
      agentMode: .headless,
      kind: kind,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      parentItemId: parentItemId,
      childOrder: childOrder,
      createdAt: "2026-01-01T00:00:00Z",
      updatedAt: "2026-01-01T00:00:00Z",
      deletedAt: deletedAt
    )
  }
}
