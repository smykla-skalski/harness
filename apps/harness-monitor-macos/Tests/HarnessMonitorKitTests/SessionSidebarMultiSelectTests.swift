import SwiftUI
import Testing

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
    state.selectedDecisionIDs = ["d1", "d2"]
    state.decisionSelectionAnchorID = "d3"

    state.pruneDecisionSelection(to: ["d2"])

    #expect(state.selectedDecisionIDs == ["d2"])
    #expect(state.decisionSelectionAnchorID == "d2")
  }
}
