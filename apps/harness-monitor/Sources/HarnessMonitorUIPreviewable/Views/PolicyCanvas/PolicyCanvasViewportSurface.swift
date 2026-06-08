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
  let resizeZoomBehavior: PolicyCanvasViewportResizeZoomBehavior
  /// When true the surface re-runs the layered layout engine on appear and after
  /// every document load, so it reflects the algorithms rather than the
  /// document's authored seed coordinates. The Policy Canvas Lab sets this; the
  /// shipping canvas (PolicyCanvasView) keeps authored layouts and never does.
  let forcesEngineLayout: Bool
  /// Monotonic token the host bumps to request a manual reformat (toolbar
  /// button). Every change re-runs the layered engine.
  let reformatRequest: Int
  /// Display name shown on the single container group that wraps the graph.
  let policyDisplayName: String?

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
    showsEdgeLegend: Bool = true,
    resizeZoomBehavior: PolicyCanvasViewportResizeZoomBehavior = .preserveZoom,
    forcesEngineLayout: Bool = false,
    reformatRequest: Int = 0,
    policyDisplayName: String? = nil
  ) {
    self.document = document
    self.simulation = simulation
    self.audit = audit
    self.algorithmSelection = algorithmSelection
    self.minimapCenteringModeOverride = minimapCenteringMode
    canvasColorSchemeOverride = canvasColorScheme
    self.showsEdgeLegend = showsEdgeLegend
    self.resizeZoomBehavior = resizeZoomBehavior
    self.forcesEngineLayout = forcesEngineLayout
    self.reformatRequest = reformatRequest
    self.policyDisplayName = policyDisplayName
    _viewModel = State(
      initialValue: PolicyCanvasViewModel.liveStartupState(
        document: document,
        simulation: simulation,
        audit: audit,
        activeCanvasId: nil,
        algorithmSelection: algorithmSelection,
        policyGroupTitle: policyDisplayName
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
      resizeZoomBehavior: resizeZoomBehavior,
      minimapCenteringModeOverride: minimapCenteringModeOverride,
      canvasColorSchemeOverride: canvasColorSchemeOverride,
      showsEdgeLegend: showsEdgeLegend
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
    .environment(\.policyCanvasReducedMotion, systemReduceMotion)
    .task {
      // The fixture/document-load path renders the document's authored positions
      // without running the auto-arrange engine, so a load shows the saved seeds
      // rather than the algorithm output. The lab wants the layered engine's
      // placement, so force an unconstrained reflow on appear. The env override
      // keeps the agent capture script working even when a caller leaves
      // forcesEngineLayout off. The shipping canvas uses PolicyCanvasView, not
      // this surface, and keeps its authored layout.
      if forcesEngineLayout
        || ProcessInfo.processInfo.environment[
          "HARNESS_MONITOR_POLICY_CANVAS_LAB_FORCE_REFLOW"
        ] == "1"
      {
        viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
      }
    }
    .onChange(of: reformatRequest, initial: false) { _, _ in
      viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
    }
    .onChange(of: snapshot, initial: false) { oldSnapshot, newSnapshot in
      viewModel.algorithmSelection = newSnapshot.algorithmSelection
      viewModel.policyGroupTitle = policyDisplayName
      if oldSnapshot.document != newSnapshot.document {
        viewModel.applyDocument(
          document: newSnapshot.document,
          simulation: newSnapshot.simulation,
          audit: newSnapshot.audit,
          forceDocumentReload: true
        )
        if forcesEngineLayout {
          viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
        }
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
