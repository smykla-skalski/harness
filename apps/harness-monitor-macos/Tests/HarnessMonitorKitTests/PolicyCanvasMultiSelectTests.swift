import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Wave 4J P03 multi-select tests. Locks the contract: primary `selection`
/// stays a single optional for inspector binding compatibility, while
/// `secondarySelections` is a set the shift-click extension layers on top.
/// `isSelected(_:)` is the single source of truth for "is this element
/// drawn with selection chrome".
@Suite("Policy canvas multi-select")
@MainActor
struct PolicyCanvasMultiSelectTests {
  @Test("Empty model starts with no selections")
  func emptySelectionAtRest() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)
    #expect(viewModel.selection == nil)
    #expect(viewModel.secondarySelections.isEmpty)
    #expect(viewModel.allSelections.isEmpty)
  }

  @Test("Primary select clears any secondary picks")
  func primarySelectDropsSecondary() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    #expect(!viewModel.secondarySelections.isEmpty)

    viewModel.select(.node("review-gate"))

    #expect(viewModel.selection == .node("review-gate"))
    #expect(viewModel.secondarySelections.isEmpty)
  }

  @Test("Shift-click on a non-selected element promotes to secondary")
  func extendAddsSecondary() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))

    viewModel.extendSelection(.node("risk-score"))

    #expect(viewModel.selection == .node("policy-source"))
    #expect(viewModel.secondarySelections.contains(.node("risk-score")))
    #expect(viewModel.isSelected(.node("risk-score")))
    #expect(viewModel.isSelected(.node("policy-source")))
  }

  @Test("Shift-click on the primary promotes a secondary or clears")
  func extendOnPrimaryPromotesSecondary() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))

    viewModel.extendSelection(.node("policy-source"))

    #expect(viewModel.selection == .node("risk-score"))
    #expect(viewModel.secondarySelections.isEmpty)
  }

  @Test("Shift-click on the primary with no secondaries clears selection")
  func extendOnLonePrimaryClears() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))

    viewModel.extendSelection(.node("policy-source"))

    #expect(viewModel.selection == nil)
    #expect(viewModel.secondarySelections.isEmpty)
  }

  @Test("Shift-click on a secondary unselects it without touching the primary")
  func extendOnSecondaryRemoves() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    #expect(viewModel.secondarySelections.contains(.node("risk-score")))

    viewModel.extendSelection(.node("risk-score"))

    #expect(viewModel.selection == .node("policy-source"))
    #expect(!viewModel.secondarySelections.contains(.node("risk-score")))
  }

  @Test("Shift-click from empty selection promotes target to primary")
  func extendFromEmptyBecomesPrimary() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)

    viewModel.extendSelection(.node("policy-source"))

    #expect(viewModel.selection == .node("policy-source"))
    #expect(viewModel.secondarySelections.isEmpty)
  }

  @Test("Cmd+A selectAll lights every node, edge, and group")
  func selectAllLightsEverything() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)

    viewModel.selectAll()

    for node in viewModel.nodes {
      #expect(viewModel.isSelected(.node(node.id)))
    }
    for edge in viewModel.edges {
      #expect(viewModel.isSelected(.edge(edge.id)))
    }
    for group in viewModel.groups {
      #expect(viewModel.isSelected(.group(group.id)))
    }
  }

  @Test("selectAll keeps existing primary when still on canvas")
  func selectAllPreservesPrimary() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))

    viewModel.selectAll()

    #expect(viewModel.selection == .node("risk-score"))
  }

  @Test("Empty graph selectAll leaves selection clear")
  func selectAllOnEmpty() {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: []
    )

    viewModel.selectAll()

    #expect(viewModel.selection == nil)
    #expect(viewModel.secondarySelections.isEmpty)
  }

  @Test("clearSelection drops both primary and secondary")
  func clearSelectionDropsAllSelections() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    viewModel.extendSelection(.edge("edge-intake-risk"))

    viewModel.clearSelection()

    #expect(viewModel.selection == nil)
    #expect(viewModel.secondarySelections.isEmpty)
  }

  @Test("selectedNodeIDs returns only selected nodes in stable model order")
  func selectedNodeIDsReturnsStableOrder() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("review-gate"))
    viewModel.extendSelection(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))

    let ids = viewModel.selectedNodeIDs

    // Same order as the model's node array, which is sample-data order.
    #expect(ids == ["policy-source", "risk-score", "review-gate"])
  }

  @Test("selectedEdgeIDs / selectedGroupIDs walk same stable order")
  func selectedNonNodeIDsStable() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.edge("edge-risk-context"))
    viewModel.extendSelection(.edge("edge-intake-risk"))
    viewModel.extendSelection(.group("group-evaluation"))
    viewModel.extendSelection(.group("group-intake"))

    let edgeIDs = viewModel.selectedEdgeIDs
    let groupIDs = viewModel.selectedGroupIDs

    // edges are in document order; same for groups.
    #expect(edgeIDs.first == "edge-intake-risk")
    #expect(edgeIDs.contains("edge-risk-context"))
    #expect(groupIDs.first == "group-intake")
    #expect(groupIDs.contains("group-evaluation"))
  }

  @Test("Cross-kind selections live in the same secondary set")
  func crossKindSelections() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.edge("edge-intake-risk"))
    viewModel.extendSelection(.group("group-evaluation"))

    #expect(viewModel.allSelections.count == 3)
    #expect(viewModel.selectedNodeIDs.count == 1)
    #expect(viewModel.selectedEdgeIDs.count == 1)
    #expect(viewModel.selectedGroupIDs.count == 1)
  }

  @Test("isSelectionLive flags stale selections")
  func isSelectionLiveDetectsStale() {
    let viewModel = PolicyCanvasViewModel.sample()
    #expect(viewModel.isSelectionLive(.node("policy-source")))
    #expect(!viewModel.isSelectionLive(.node("does-not-exist")))
    #expect(viewModel.isSelectionLive(.edge("edge-intake-risk")))
    #expect(!viewModel.isSelectionLive(.edge("ghost-edge")))
    #expect(viewModel.isSelectionLive(.group("group-evaluation")))
    #expect(!viewModel.isSelectionLive(.group("phantom-group")))
  }

  @Test("Multi-select does not affect documentDirty (selection-only)")
  func multiSelectStaysCleanOnDocument() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false

    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    viewModel.selectAll()
    viewModel.clearSelection()

    #expect(!viewModel.documentDirty)
  }
}
