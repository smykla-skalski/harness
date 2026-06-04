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
    .task {
      // Lab capture affordance. The fixture-load path renders the document's
      // authored positions without running the auto-arrange engine, so an agent
      // screenshot of a fixture shows the saved seeds, not the engine output.
      // When this env is set the surface forces an unconstrained reflow on
      // appear so the capture reflects the layered engine. The shipping policy
      // canvas uses PolicyCanvasView, not this surface, and never sets the env.
      if ProcessInfo.processInfo.environment[
        "HARNESS_MONITOR_POLICY_CANVAS_LAB_FORCE_REFLOW"
      ] == "1" {
        viewModel.reflowLayout(preserveManualAnchors: false, force: true)
      }
    }
    .onChange(of: snapshot, initial: false) { oldSnapshot, newSnapshot in
      viewModel.algorithmSelection = newSnapshot.algorithmSelection
      if oldSnapshot.document != newSnapshot.document {
        viewModel.applyDocument(
          document: newSnapshot.document,
          simulation: newSnapshot.simulation,
          audit: newSnapshot.audit,
          forceDocumentReload: true
        )
      } else {
        viewModel.loadIfChanged(
          document: newSnapshot.document,
          simulation: newSnapshot.simulation,
          audit: newSnapshot.audit
        )
      }
    }
  }
}
