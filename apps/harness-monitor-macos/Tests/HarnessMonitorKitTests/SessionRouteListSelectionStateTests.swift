import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session route list selection state")
struct SessionRouteListSelectionStateTests {
  @Test("Displayed selection falls back to the current primary row")
  func displayedSelectionFallsBackToPrimary() {
    let state = SessionRouteListSelectionState()

    #expect(state.displayedSelection(fallbackPrimaryID: "task-ui") == Set(["task-ui"]))
    #expect(!state.hasActiveMultiSelection(fallbackPrimaryID: "task-ui"))
  }

  @Test("Applying multi-selection tracks the added row as the primary anchor")
  func applyingMultiSelectionTracksAddedRow() {
    var state = SessionRouteListSelectionState()

    let primaryID = state.applySelection(
      ["task-ui", "task-routing"],
      fallbackPrimaryID: "task-ui"
    )

    #expect(state.selectedIDs == Set(["task-ui", "task-routing"]))
    #expect(state.anchorID == "task-routing")
    #expect(primaryID == "task-routing")
    #expect(state.hasActiveMultiSelection(fallbackPrimaryID: "task-ui"))
  }

  @Test("Pruning hidden rows collapses back to the remaining visible row")
  func pruningHiddenRowsCollapsesToVisibleRow() {
    var state = SessionRouteListSelectionState()
    _ = state.applySelection(
      ["task-ui", "task-routing"],
      fallbackPrimaryID: "task-ui"
    )

    let primaryID = state.prune(
      visibleIDs: Set(["task-ui"]),
      fallbackPrimaryID: "task-ui"
    )

    #expect(state.selectedIDs == Set(["task-ui"]))
    #expect(state.anchorID == "task-ui")
    #expect(primaryID == "task-ui")
    #expect(!state.hasActiveMultiSelection(fallbackPrimaryID: "task-ui"))
  }
}
