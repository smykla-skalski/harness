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
  let forcesAutoArrange: Bool

  @State private var viewModel: PolicyCanvasViewModel
  @AccessibilityFocusState private var focusedComponentState: PolicyCanvasSelection?
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  @MainActor
  public init(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    forcesAutoArrange: Bool = false
  ) {
    self.document = document
    self.simulation = simulation
    self.audit = audit
    self.forcesAutoArrange = forcesAutoArrange
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
    .environment(\.policyCanvasReducedMotion, systemReduceMotion)
    .task {
      if forcesAutoArrange {
        viewModel.reflowLayout(preserveManualAnchors: false, force: true)
      }
    }
    .onChange(of: snapshot, initial: false) { _, newSnapshot in
      viewModel.loadIfChanged(
        document: newSnapshot.document,
        simulation: newSnapshot.simulation,
        audit: newSnapshot.audit
      )
      if forcesAutoArrange {
        viewModel.reflowLayout(preserveManualAnchors: false, force: true)
      }
    }
  }
}
