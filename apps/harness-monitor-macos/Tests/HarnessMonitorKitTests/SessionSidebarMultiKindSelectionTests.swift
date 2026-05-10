import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session sidebar multi-kind selection")
struct SessionSidebarMultiKindSelectionTests {
  @MainActor
  @Test("applyChange anchors to first kind and locks subsequent same-kind changes")
  func applyChangeAnchorsAndLocks() {
    let state = SessionSidebarSelectionState()
    state.applyChange(kind: .agent, selectedIDs: ["a1", "a2"], anchorID: "a1")

    #expect(state.selectedAgentIDs == ["a1", "a2"])
    #expect(state.anchor == SessionSidebarAnchor(kind: .agent, id: "a1"))
    #expect(state.count(of: .agent) == 2)
    #expect(state.count(of: .task) == 0)
    #expect(state.count(of: .decision) == 0)

    state.applyChange(kind: .agent, selectedIDs: ["a1", "a2", "a3"], anchorID: "a3")

    #expect(state.selectedAgentIDs == ["a1", "a2", "a3"])
    #expect(state.anchor?.id == "a3")
  }

  @MainActor
  @Test("applyChange resets other kinds when anchor switches type")
  func applyChangeResetsOtherKindsOnSwitch() {
    let state = SessionSidebarSelectionState()
    state.applyChange(kind: .agent, selectedIDs: ["a1", "a2"], anchorID: "a1")

    state.applyChange(kind: .task, selectedIDs: ["t1"], anchorID: "t1")

    #expect(state.selectedAgentIDs.isEmpty)
    #expect(state.selectedTaskIDs == ["t1"])
    #expect(state.anchor == SessionSidebarAnchor(kind: .task, id: "t1"))
  }

  @MainActor
  @Test("clear empties all sets and anchor")
  func clearEmptiesEverything() {
    let state = SessionSidebarSelectionState()
    state.applyChange(kind: .decision, selectedIDs: ["d1", "d2"], anchorID: "d1")
    state.clear()

    #expect(state.selectedDecisionIDs.isEmpty)
    #expect(state.anchor == nil)
  }

  @MainActor
  @Test("Rendered selection count keeps mixed multi-selection active")
  func renderedSelectionCountKeepsMixedMultiSelectionActive() {
    let state = SessionSidebarSelectionState()

    #expect(!state.hasActiveMultiSelection)
    state.syncRenderedSelectionCount(2)
    #expect(state.hasActiveMultiSelection)
    state.syncRenderedSelectionCount(1)
    #expect(!state.hasActiveMultiSelection)
  }

  @MainActor
  @Test("prune intersects with visible IDs and repairs anchor")
  func prunePerKind() {
    let state = SessionSidebarSelectionState()
    state.applyChange(kind: .task, selectedIDs: ["t1", "t2", "t3"], anchorID: "t3")
    state.prune(kind: .task, visibleIDs: ["t1", "t2"])

    #expect(state.selectedTaskIDs == ["t1", "t2"])
    let anchor = state.anchor
    #expect(anchor?.kind == .task)
    #expect(anchor.map { ["t1", "t2"].contains($0.id) } == true)
  }

  @Test("Context menu scope picks selection when row is part of it")
  func contextMenuScopePicksSelection() {
    let scope = SessionSidebarContextMenuScope.resolve(
      kind: .agent,
      rowID: "a2",
      selectedIDs: ["a1", "a2", "a3"],
      orderedVisibleIDs: ["a1", "a2", "a3", "a4"]
    )
    #expect(scope.isMulti)
    #expect(scope.ids == ["a1", "a2", "a3"])
    #expect(scope.copyIDsLabel == "Copy 3 Agent IDs")
    #expect(scope.destructiveLabel == "Remove 3 Agents")
  }

  @Test("Context menu scope falls back to single row when not in selection")
  func contextMenuScopeFallsBackToSingleRow() {
    let scope = SessionSidebarContextMenuScope.resolve(
      kind: .task,
      rowID: "t9",
      selectedIDs: ["t1", "t2"],
      orderedVisibleIDs: ["t1", "t2", "t9"]
    )
    #expect(!scope.isMulti)
    #expect(scope.ids == ["t9"])
    #expect(scope.copyIDsLabel == "Copy Task ID")
    #expect(scope.destructiveLabel == "Delete Task")
  }

  @Test("Decision scope renders dismiss copy")
  func decisionScopeRendersDismiss() {
    let scope = SessionSidebarContextMenuScope.resolve(
      kind: .decision,
      rowID: "d1",
      selectedIDs: ["d1", "d2"],
      orderedVisibleIDs: ["d1", "d2"]
    )
    #expect(scope.destructiveLabel == "Dismiss 2 Decisions")
  }

  @Test("Mixed selection disables context menu actions on selected rows")
  func mixedSelectionDisablesContextMenuActions() {
    let selectedAgent = SessionSelection.agent(sessionID: "s1", agentID: "a2")
    let resolution = SessionSidebarContextMenuScope.resolve(
      kind: .agent,
      rowID: "a2",
      selectionState: .init(
        rowSelection: selectedAgent,
        listSelection: [.route(.overview), selectedAgent]
      ),
      selectedIDs: [],
      orderedVisibleIDs: ["a1", "a2", "a3"]
    )

    #expect(
      resolution == .unavailable(SessionSidebarContextMenuScope.mixedSelectionUnavailableLabel)
    )
  }

  @Test("Same-kind selection keeps actionable context menu actions")
  func sameKindSelectionKeepsActionableContextMenu() {
    let first = SessionSelection.task(sessionID: "s1", taskID: "t1")
    let second = SessionSelection.task(sessionID: "s1", taskID: "t2")
    let resolution = SessionSidebarContextMenuScope.resolve(
      kind: .task,
      rowID: "t2",
      selectionState: .init(
        rowSelection: second,
        listSelection: [first, second]
      ),
      selectedIDs: ["t1", "t2"],
      orderedVisibleIDs: ["t1", "t2", "t3"]
    )

    guard case .actionable(let scope) = resolution else {
      Issue.record("Expected the task multi-selection context menu to stay actionable")
      return
    }

    #expect(scope.ids == ["t1", "t2"])
    #expect(scope.copyIDsLabel == "Copy 2 Task IDs")
  }

  @MainActor
  @Test("Announcer copy mentions kind and counts")
  func announcerCopyPerKind() {
    #expect(
      SessionSidebarMultiSelectAnnouncer.announcementCopy(
        kind: .agent,
        count: 3,
        visibleCount: 7
      ) == "3 of 7 agents selected"
    )
    #expect(
      SessionSidebarMultiSelectAnnouncer.announcementCopy(
        kind: .task,
        count: 2,
        visibleCount: 4
      ) == "2 of 4 tasks selected"
    )
    #expect(
      SessionSidebarMultiSelectAnnouncer.announcementCopy(
        kind: .decision,
        count: 1,
        visibleCount: 5
      ) == "1 of 5 decisions selected"
    )
    #expect(
      SessionSidebarMultiSelectAnnouncer.announcementCopy(
        kind: .agent,
        count: 0,
        visibleCount: 0
      ) == "Selection cleared"
    )
  }

  @Test("PendingConfirmation surfaces plural trace labels")
  func pendingConfirmationTraceLabels() {
    #expect(
      HarnessMonitorStore.PendingConfirmation
        .removeAgents(sessionID: "s1", agentIDs: ["a1", "a2"], actorID: "actor")
        .uiTestTraceLabel == "remove-agents"
    )
    #expect(
      HarnessMonitorStore.PendingConfirmation
        .deleteTasks(sessionID: "s1", taskIDs: ["t1", "t2"], actorID: "actor")
        .uiTestTraceLabel == "delete-tasks"
    )
  }
}
