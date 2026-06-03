import HarnessMonitorKit
import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

private struct PolicyCanvasViewportSurfaceSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let algorithmSelection: PolicyCanvasAlgorithmSelection
}

@MainActor
public struct PolicyCanvasViewportSurface: View {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let algorithmSelection: PolicyCanvasAlgorithmSelection

  @State private var viewModel: PolicyCanvasViewModel
  @AccessibilityFocusState private var focusedComponentState: PolicyCanvasSelection?
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  @MainActor
  public init(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .harnessCurrent
  ) {
    self.document = document
    self.simulation = simulation
    self.audit = audit
    self.algorithmSelection = algorithmSelection
    _viewModel = State(
      initialValue: PolicyCanvasViewModel.liveStartupState(
        document: document,
        simulation: simulation,
        audit: audit,
        activeCanvasId: nil,
        algorithmSelection: algorithmSelection
      )
    )
  }

  private var snapshot: PolicyCanvasViewportSurfaceSnapshot {
    PolicyCanvasViewportSurfaceSnapshot(
      document: document,
      simulation: simulation,
      audit: audit,
      algorithmSelection: algorithmSelection
    )
  }

  public var body: some View {
    PolicyCanvasViewport(
      viewModel: viewModel,
      focusedComponent: $focusedComponentState,
      suppressesSceneStorage: true,
      storedPipelineStateRaw: ""
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
    .environment(\.policyCanvasReducedMotion, systemReduceMotion)
    .onChange(of: snapshot, initial: false) { _, newSnapshot in
      viewModel.algorithmSelection = newSnapshot.algorithmSelection
      viewModel.loadIfChanged(
        document: newSnapshot.document,
        simulation: newSnapshot.simulation,
        audit: newSnapshot.audit
      )
    }
    #if DEBUG
    // Hot reload: when InjectionIII / InjectionNext swaps the layout or routing
    // code, recompute so the new positions and routes replace the cached graph,
    // then chime so you know to glance at the window. A redraw alone keeps the
    // pre-edit layout (positions are cached and routes are generation-gated).
    // See PolicyCanvasHotReload.
    .onReceive(NotificationCenter.default.publisher(for: PolicyCanvasHotReload.injectionNotification)) { _ in
      viewModel.applyHotReloadedAlgorithms(
        document: document,
        simulation: simulation,
        audit: audit
      )
      PolicyCanvasHotReload.playReloadChime()
    }
    #endif
  }
}
