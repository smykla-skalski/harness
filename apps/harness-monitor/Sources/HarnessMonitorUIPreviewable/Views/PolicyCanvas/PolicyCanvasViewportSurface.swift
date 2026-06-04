import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private struct PolicyCanvasViewportSurfaceSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let algorithmSelection: PolicyCanvasAlgorithmSelection
}

public struct PolicyCanvasViewportSurface: View {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let algorithmSelection: PolicyCanvasAlgorithmSelection
  let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
  let canvasColorSchemeOverride: ColorScheme?
  let showsEdgeLegend: Bool

  @State private var viewModel: PolicyCanvasViewModel
  @AccessibilityFocusState private var focusedComponentState: PolicyCanvasSelection?
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  @MainActor
  public init(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting,
    minimapCenteringMode: PolicyCanvasMinimapCenteringMode? = nil,
    canvasColorScheme: ColorScheme? = nil,
    showsEdgeLegend: Bool = true
  ) {
    self.document = document
    self.simulation = simulation
    self.audit = audit
    self.algorithmSelection = algorithmSelection
    self.minimapCenteringModeOverride = minimapCenteringMode
    canvasColorSchemeOverride = canvasColorScheme
    self.showsEdgeLegend = showsEdgeLegend
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
      storedPipelineStateRaw: "",
      minimapCenteringModeOverride: minimapCenteringModeOverride,
      canvasColorSchemeOverride: canvasColorSchemeOverride,
      showsEdgeLegend: showsEdgeLegend
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
  }
}
