import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Sidebar session list selection sync")
struct SidebarSessionListSelectionSyncTests {
  @Test("preserves hidden selection during filter reconciliation")
  func preservesHiddenSelectionDuringFilterReconciliation() {
    let change = SidebarSessionListSelectionSync.resolve(
      previousSelection: ["sess1234", "sess5678"],
      newRenderedSelection: ["sess1234"],
      visibleSessionIDs: ["sess1234"],
      storeSelectedSessionID: "sess1234"
    )

    #expect(change.nextSelection == ["sess1234", "sess5678"])
    #expect(change.storeSelection == .unchanged)
  }

  @Test("single selection still syncs to the cockpit")
  func singleSelectionSyncsToStore() {
    let change = SidebarSessionListSelectionSync.resolve(
      previousSelection: [],
      newRenderedSelection: ["sess5678"],
      visibleSessionIDs: ["sess1234", "sess5678"],
      storeSelectedSessionID: "sess1234"
    )

    #expect(change.nextSelection == ["sess5678"])
    #expect(change.storeSelection == .selected("sess5678"))
  }

  @Test("multi-select extension stays local to the sidebar")
  func multiselectExtensionStaysLocal() {
    let change = SidebarSessionListSelectionSync.resolve(
      previousSelection: ["sess1234"],
      newRenderedSelection: ["sess1234", "sess5678"],
      visibleSessionIDs: ["sess1234", "sess5678"],
      storeSelectedSessionID: "sess1234"
    )

    #expect(change.nextSelection == ["sess1234", "sess5678"])
    #expect(change.storeSelection == .unchanged)
  }

  @Test("collapsing a visible multi-select keeps the cockpit pinned")
  func collapseToSingleRowKeepsCockpitPinned() {
    let change = SidebarSessionListSelectionSync.resolve(
      previousSelection: ["sess1234", "sess5678"],
      newRenderedSelection: ["sess5678"],
      visibleSessionIDs: ["sess1234", "sess5678"],
      storeSelectedSessionID: "sess1234"
    )

    #expect(change.nextSelection == ["sess5678"])
    #expect(change.storeSelection == .unchanged)
  }

  @Test("single-selection replacement still syncs to the cockpit")
  func replacingSingleSelectionSyncsToStore() {
    let change = SidebarSessionListSelectionSync.resolve(
      previousSelection: ["sess1234"],
      newRenderedSelection: ["sess5678"],
      visibleSessionIDs: ["sess1234", "sess5678"],
      storeSelectedSessionID: "sess1234"
    )

    #expect(change.nextSelection == ["sess5678"])
    #expect(change.storeSelection == .selected("sess5678"))
  }

  @Test("semantic activation collapses local selection and syncs the cockpit")
  func semanticActivationSyncsToStore() {
    let change = SidebarSessionListSelectionSync.semanticActivation(
      sessionID: "sess5678",
      storeSelectedSessionID: "sess1234"
    )

    #expect(change.nextSelection == ["sess5678"])
    #expect(change.storeSelection == .selected("sess5678"))
  }

  @Test("semantic activation stays unchanged when the session is already selected")
  func semanticActivationKeepsStoreSelectionWhenAlreadySelected() {
    let change = SidebarSessionListSelectionSync.semanticActivation(
      sessionID: "sess5678",
      storeSelectedSessionID: "sess5678"
    )

    #expect(change.nextSelection == ["sess5678"])
    #expect(change.storeSelection == .unchanged)
  }

  @Test("explicit single selection collapses local selection and syncs the cockpit")
  func explicitSingleSelectionSyncsToStore() {
    let change = SidebarSessionListSelectionSync.explicitSingleSelection(
      sessionID: "sess5678",
      storeSelectedSessionID: "sess1234"
    )

    #expect(change.nextSelection == ["sess5678"])
    #expect(change.storeSelection == .selected("sess5678"))
  }

  @Test("explicit single selection stays unchanged when the session is already selected")
  func explicitSingleSelectionKeepsStoreSelectionWhenAlreadySelected() {
    let change = SidebarSessionListSelectionSync.explicitSingleSelection(
      sessionID: "sess5678",
      storeSelectedSessionID: "sess5678"
    )

    #expect(change.nextSelection == ["sess5678"])
    #expect(change.storeSelection == .unchanged)
  }
}
