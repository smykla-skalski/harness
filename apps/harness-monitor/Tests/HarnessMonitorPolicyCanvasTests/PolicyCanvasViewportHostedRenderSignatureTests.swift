import AppKit
import Foundation
import SwiftUI
import Testing
import os

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// Guards the scroll hot path: a viewport scroll must not republish the hosted
/// snapshot when nothing the canvas renders has changed. The render signature
/// is the cheap change-detector `PolicyCanvasViewportHostedState.update(snapshot:)`
/// compares before reassigning its `@Observable` snapshot, so a pure pan keeps
/// the entire content tree (grid, nodes, edges, labels) off the re-eval path.
@MainActor
@Suite
struct PolicyCanvasViewportHostedRenderSignatureTests {
  @Test("identical render inputs produce an equal signature")
  func equalForIdenticalInputs() {
    let focus = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    let lhs = makeSnapshot(viewModel: viewModel, focusedComponent: focus)
    let rhs = makeSnapshot(viewModel: viewModel, focusedComponent: focus)
    #expect(lhs.renderSignature == rhs.renderSignature)
  }

  @Test("toggling the simulation overlay changes the signature")
  func differsWhenSimulationOverlayChanges() {
    let focus = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    let lhs = makeSnapshot(
      viewModel: viewModel, focusedComponent: focus, showSimulationOverlay: false)
    let rhs = makeSnapshot(
      viewModel: viewModel, focusedComponent: focus, showSimulationOverlay: true)
    #expect(lhs.renderSignature != rhs.renderSignature)
  }

  @Test("a different resolved color scheme changes the signature")
  func differsWhenColorSchemeChanges() {
    let focus = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    let lhs = makeSnapshot(
      viewModel: viewModel, focusedComponent: focus, resolvedCanvasColorScheme: .light)
    let rhs = makeSnapshot(
      viewModel: viewModel, focusedComponent: focus, resolvedCanvasColorScheme: .dark)
    #expect(lhs.renderSignature != rhs.renderSignature)
  }

  @Test("new node-validation messages change the signature")
  func differsWhenValidationMessagesChange() {
    let focus = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    let firstNodeID = viewModel.nodes.first?.id ?? "node"
    let lhs = makeSnapshot(viewModel: viewModel, focusedComponent: focus)
    let rhs = makeSnapshot(
      viewModel: viewModel,
      focusedComponent: focus,
      nodeValidationIssueMessagesByID: [firstNodeID: "missing policy binding"]
    )
    #expect(lhs.renderSignature != rhs.renderSignature)
  }

  @Test("a changed route output changes the signature")
  func differsWhenRouteOutputChanges() {
    let focus = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    let baseline = makeSnapshot(viewModel: viewModel, focusedComponent: focus)
    let emptyRouteOutput = PolicyCanvasRouteWorkerOutput.empty
    let mutated = makeSnapshot(
      viewModel: viewModel,
      focusedComponent: focus,
      routeOutput: emptyRouteOutput
    )
    #expect(baseline.renderSignature != mutated.renderSignature)
  }

  @Test("a render-identical update does not republish the hosted snapshot")
  func equalSignatureDoesNotRepublishSnapshot() {
    let focus = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    let state = PolicyCanvasViewportHostedState(
      snapshot: makeSnapshot(viewModel: viewModel, focusedComponent: focus)
    )
    let didNotify = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = state.snapshot
    } onChange: {
      didNotify.withLock { $0 = true }
    }
    // A pure scroll re-runs the parent viewport body and calls update(snapshot:)
    // with a freshly built but render-identical snapshot. The guard must swallow
    // it so the hosted content tree stays off the scroll hot path: zero observer
    // notifications, where the unguarded path fired one per scroll frame.
    state.update(snapshot: makeSnapshot(viewModel: viewModel, focusedComponent: focus))
    #expect(didNotify.withLock { $0 } == false)
  }

  @Test("a render-changing update republishes the hosted snapshot")
  func changedSignatureRepublishesSnapshot() {
    let focus = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    let state = PolicyCanvasViewportHostedState(
      snapshot: makeSnapshot(
        viewModel: viewModel,
        focusedComponent: focus,
        showSimulationOverlay: false
      )
    )
    let didNotify = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = state.snapshot
    } onChange: {
      didNotify.withLock { $0 = true }
    }
    state.update(
      snapshot: makeSnapshot(
        viewModel: viewModel,
        focusedComponent: focus,
        showSimulationOverlay: true
      )
    )
    #expect(didNotify.withLock { $0 } == true)
  }

  private func makeSnapshot(
    viewModel: PolicyCanvasViewModel,
    focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding,
    routeOutput: PolicyCanvasRouteWorkerOutput? = nil,
    nodeValidationIssueMessagesByID: [String: String] = [:],
    resolvedCanvasColorScheme: ColorScheme? = nil,
    showSimulationOverlay: Bool = false
  ) -> PolicyCanvasViewportHostedSnapshot {
    let output =
      routeOutput
      ?? PolicyCanvasRouteWorkerOutput.fallback(
        for: PolicyCanvasRouteWorkerInput(
          nodes: viewModel.nodes,
          groups: viewModel.groups,
          edges: viewModel.edges,
          fontScale: 1
        )
      )
    return PolicyCanvasViewportHostedSnapshot(
      viewModel: viewModel,
      focusedComponent: focusedComponent,
      edges: viewModel.edges,
      routes: output.routes,
      labelPositions: output.labelPositions,
      accessibilityLabelsByEdgeID: output.accessibilityEdgeLabelsByID,
      accessibilityNodeEntries: output.accessibilityNodeEntries,
      accessibilityEdgeEntries: output.accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: output.nodeAccessibilityValuesByID,
      connectTargetsByNodeID: output.connectTargetsByNodeID,
      nodeValidationIssueMessagesByID: nodeValidationIssueMessagesByID,
      portVisibility: output.portVisibility,
      portMarkerLayout: output.portMarkerLayout,
      routeSignature: output.signature,
      contentSize: output.contentSize,
      resolvedCanvasColorScheme: resolvedCanvasColorScheme,
      showSimulationOverlay: showSimulationOverlay,
      openEditor: { _ in },
      requestKeyboardFocus: {}
    )
  }
}
