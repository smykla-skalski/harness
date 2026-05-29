import HarnessMonitorKit
import SwiftUI

private struct PolicyCanvasViewportSurfaceSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

public struct PolicyCanvasViewportSurface: View {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?

  @State private var viewModel: PolicyCanvasViewModel
  @AccessibilityFocusState private var focusedComponentState: PolicyCanvasSelection?
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  @MainActor
  public init(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) {
    self.document = document
    self.simulation = simulation
    self.audit = audit
    _viewModel = State(
      initialValue: PolicyCanvasViewModel.liveStartupState(
        document: document,
        simulation: simulation,
        audit: audit,
        activeCanvasId: nil
      )
    )
  }

  private var snapshot: PolicyCanvasViewportSurfaceSnapshot {
    PolicyCanvasViewportSurfaceSnapshot(
      document: document,
      simulation: simulation,
      audit: audit
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
    .background(PolicyCanvasVisualStyle.rootBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
    .environment(\.policyCanvasReducedMotion, systemReduceMotion)
    .onChange(of: snapshot, initial: false) { _, newSnapshot in
      viewModel.loadIfChanged(
        document: newSnapshot.document,
        simulation: newSnapshot.simulation,
        audit: newSnapshot.audit
      )
    }
  }
}
