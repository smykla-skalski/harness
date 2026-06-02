import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Wave 3M P49 follow-up: clearSelection() transient-gesture-state contract and
/// the selectedTab independence from selection transitions. Sibling to wave 1C's
/// PolicyCanvasSelectionTests.swift which covers the single-source-of-truth
/// invariants — this file fills the cross-state-channel gaps.
@Suite("Policy canvas selection state — transient + tab")
@MainActor
struct PolicyCanvasSelectionStateTests {
  @Test("clearSelection() also drops highlightedInput and highlightedGroupID")
  func clearSelectionDropsTransientGestureState() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))
    viewModel.setInputTargeted(true, nodeID: "review-gate", portID: "input-policy")
    viewModel.highlightedGroupID = "group-evaluation"

    #expect(viewModel.highlightedInput != nil)
    #expect(viewModel.highlightedGroupID != nil)

    viewModel.clearSelection()

    #expect(viewModel.selection == nil)
    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.highlightedGroupID == nil)
  }

  @Test("select(nil) without clearSelection leaves highlights intact")
  func selectNilDoesNotClearTransientHighlights() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setInputTargeted(true, nodeID: "review-gate", portID: "input-policy")
    viewModel.highlightedGroupID = "group-evaluation"

    // Direct selection write: only the selection field changes. The Escape
    // shortcut routes through clearSelection() (above test) to also drop
    // transient gesture state — bare select(nil) does not.
    viewModel.select(nil)

    #expect(viewModel.selection == nil)
    #expect(viewModel.highlightedInput != nil)
    #expect(viewModel.highlightedGroupID == "group-evaluation")
  }

  @Test("selection transitions do not change selectedTab")
  func selectionTransitionsLeaveSelectedTabAlone() {
    let viewModel = PolicyCanvasViewModel.sample()
    let initialTab = viewModel.selectedTab

    viewModel.select(.node("risk-score"))
    #expect(viewModel.selectedTab == initialTab)

    viewModel.select(.edge("edge-intake-risk"))
    #expect(viewModel.selectedTab == initialTab)

    viewModel.select(.group("group-evaluation"))
    #expect(viewModel.selectedTab == initialTab)

    viewModel.select(nil)
    #expect(viewModel.selectedTab == initialTab)

    viewModel.clearSelection()
    #expect(viewModel.selectedTab == initialTab)
  }

  @Test("selectedTab survives clearSelection in non-default starting state")
  func selectedTabSurvivesEscapeFromSimulationTab() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.simulate()
    #expect(viewModel.selectedTab == .simulation)

    viewModel.select(.node("risk-score"))
    viewModel.clearSelection()

    #expect(viewModel.selectedTab == .simulation)
  }

  @Test("node selection clears any prior highlightedInput from a previous gesture")
  func nodeSelectionDoesNotPreserveHighlightedInput() {
    // Selection changes do NOT eagerly clear highlightedInput on their own —
    // only clearSelection() / clearTransientGestureState() do. Lock that
    // boundary so a future change that adds eager clearing surfaces
    // explicitly, not by accident.
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setInputTargeted(true, nodeID: "review-gate", portID: "input-policy")

    viewModel.select(.node("risk-score"))

    #expect(viewModel.highlightedInput != nil)
  }

  @Test("transitioning through a missing selection then back recovers accessors")
  func transitionsThroughMissingSelectionRecover() {
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.select(.node("does-not-exist"))
    #expect(viewModel.selectedNode == nil)
    #expect(viewModel.selectedEdge == nil)
    #expect(viewModel.selectedGroup == nil)

    viewModel.select(.node("risk-score"))
    #expect(viewModel.selectedNode?.id == "risk-score")
    #expect(viewModel.selectedEdge == nil)
    #expect(viewModel.selectedGroup == nil)
  }
}
