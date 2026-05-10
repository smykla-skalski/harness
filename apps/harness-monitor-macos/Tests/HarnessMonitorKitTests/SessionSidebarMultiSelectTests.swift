import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session sidebar multi-select")
struct SessionSidebarMultiSelectTests {
  @Test("Plain click on selected row preserves multi-selection and activates row")
  func plainClickOnSelectedRowPreservesMultiSelection() {
    let change = SessionSidebarMultiSelect.resolve(
      rowID: "d2",
      orderedVisibleIDs: ["d1", "d2", "d3"],
      selectedIDs: ["d1", "d2"],
      anchorID: "d1",
      modifiers: []
    )

    #expect(change.selectedIDs == ["d1", "d2"])
    #expect(change.anchorID == "d2")
    #expect(change.activatesRow)
  }

  @Test("Plain click on unselected row replaces multi-selection and activates row")
  func plainClickOnUnselectedRowReplacesMultiSelection() {
    let change = SessionSidebarMultiSelect.resolve(
      rowID: "d3",
      orderedVisibleIDs: ["d1", "d2", "d3"],
      selectedIDs: ["d1", "d2"],
      anchorID: "d1",
      modifiers: []
    )

    #expect(change.selectedIDs == ["d3"])
    #expect(change.anchorID == "d3")
    #expect(change.activatesRow)
  }

  @Test("Command click toggles without activating row")
  func commandClickTogglesSelection() {
    let deselect = SessionSidebarMultiSelect.resolve(
      rowID: "d2",
      orderedVisibleIDs: ["d1", "d2", "d3"],
      selectedIDs: ["d1", "d2"],
      anchorID: "d1",
      modifiers: .command
    )
    let select = SessionSidebarMultiSelect.resolve(
      rowID: "d3",
      orderedVisibleIDs: ["d1", "d2", "d3"],
      selectedIDs: deselect.selectedIDs,
      anchorID: deselect.anchorID,
      modifiers: .command
    )

    #expect(deselect.selectedIDs == ["d1"])
    #expect(!deselect.activatesRow)
    #expect(select.selectedIDs == ["d1", "d3"])
    #expect(select.anchorID == "d3")
    #expect(!select.activatesRow)
  }

  @Test("Shift click extends from the anchor through visible order")
  func shiftClickExtendsFromAnchor() {
    let change = SessionSidebarMultiSelect.resolve(
      rowID: "d4",
      orderedVisibleIDs: ["d1", "d2", "d3", "d4"],
      selectedIDs: ["d1"],
      anchorID: "d2",
      modifiers: .shift
    )

    #expect(change.selectedIDs == ["d1", "d2", "d3", "d4"])
    #expect(change.anchorID == "d2")
    #expect(!change.activatesRow)
  }

  @MainActor
  @Test("Pruning visible decisions also repairs stale anchor")
  func pruningRepairsStaleAnchor() {
    let state = SessionSidebarSelectionState()
    state.applyChange(kind: .decision, selectedIDs: ["d1", "d2"], anchorID: "d3")

    state.prune(kind: .decision, visibleIDs: ["d2"])

    #expect(state.selectedDecisionIDs == ["d2"])
    #expect(state.anchor == SessionSidebarAnchor(kind: .decision, id: "d2"))
  }

  @MainActor
  @Test("Task move helper records the expected decision link")
  func taskMoveHelperRecordsDecisionLink() {
    let state = SessionWindowStateCache(sessionID: "session-1")
    let sidebar = SessionSidebar(
      store: HarnessMonitorStore(daemonController: PreviewDaemonController(mode: .empty)),
      snapshot: nil,
      sessionCodexRuns: [],
      decisions: [],
      canPresentSearch: true,
      state: state
    )

    sidebar.linkTask("task-1", to: "decision-1")

    let expectedLink = SessionTaskDecisionLink(
      sessionID: "session-1",
      taskID: "task-1",
      decisionID: "decision-1"
    )

    #expect(state.lastTaskDecisionLink == expectedLink)
  }

  @Test("Sidebar task rows expose Move to context menus")
  func taskRowsExposeMoveToContextMenus() throws {
    let source = try sourceFile(named: "SessionSidebar+Sections.swift")

    #expect(source.contains("Menu(\"Move to...\")"))
    #expect(source.contains("No visible decisions"))
    #expect(source.contains("Filter decisions to show more"))
  }

  @Test("Sidebar rows remove drag handle and drop target chrome")
  func sidebarRowsRemoveDragHandleAndDropTargetChrome() throws {
    let source = try sourceFile(named: "SessionSidebarRow.swift")

    #expect(!source.contains("showsDragHandle"))
    #expect(!source.contains("SessionSidebarDragHandle"))
    #expect(!source.contains("isHoveringDragHandle"))
    #expect(!source.contains("SessionSidebarDragHandleGlyph"))
    #expect(!source.contains("path.addEllipse"))
    #expect(!source.contains("for column in 0..<2"))
    #expect(!source.contains("for row in 0..<3"))
    #expect(!source.contains(".overlay(alignment: .trailing)"))
    #expect(!source.contains(".onHover"))
    #expect(!source.contains("isDropTargeted"))
    #expect(!source.contains("dragHandleHitTarget"))
    #expect(!source.contains("dropCornerRadius"))
  }

  @Test("Sidebar rows rely on native List selection instead of tap gestures")
  func sidebarRowsRelyOnNativeListSelection() throws {
    let source = try sourceFile(named: "SessionSidebar.swift")

    #expect(!source.contains("pointerSelectionGesture"))
    #expect(!source.contains(".simultaneousGesture("))
  }

  @Test("Sidebar collapse helpers resync stored list selection")
  func sidebarCollapseHelpersResyncStoredListSelection() throws {
    let source = try sourceFile(named: "SessionSidebar.swift")

    #expect(source.contains("setListSelection([selection])"))
    #expect(source.contains("setListSelection([state.selection])"))
    #expect(source.contains("state.sidebarSelection.syncRenderedSelectionCount(selection.count)"))
  }

  @Test("Session sidebar search is availability gated")
  func sessionSidebarSearchIsAvailabilityGated() throws {
    let sidebarSource = try sourceFile(named: "SessionSidebar.swift")
    let columnsSource = try sourceFile(named: "SessionWindowView+Columns.swift")

    #expect(sidebarSource.contains("isPresented: $searchPresentationState.isPresented"))
    #expect(sidebarSource.contains("applySearchPresentationAvailability"))
    #expect(
      sidebarSource.contains(
        ".harnessFocusedSceneValue(\\.harnessSidebarSearchFocusAction, searchFocusAction)"
      )
    )
    #expect(columnsSource.contains("canPresentSearch: sessionSidebarSearchAvailable"))
  }

  @Test("Sidebar sources no longer install drag and drop")
  func sidebarSourcesNoLongerInstallDragAndDrop() throws {
    let sidebarSource = try sourceFile(named: "SessionSidebar.swift")
    let decisionSource = try sourceFile(named: "SessionSidebarDecisionSection.swift")
    let rowSource = try sourceFile(named: "SessionSidebarRow.swift")

    #expect(!rowSource.contains("AnyView"))
    #expect(rowSource.contains(".contentShape(Rectangle())"))
    #expect(!sidebarSource.contains(".draggable("))
    #expect(!sidebarSource.contains(".dropDestination("))
    #expect(!sidebarSource.contains("SessionAgentDragPayload"))
    #expect(!sidebarSource.contains("TaskDragPayload("))
    #expect(!decisionSource.contains(".dropDestination("))
  }

  private func sourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
