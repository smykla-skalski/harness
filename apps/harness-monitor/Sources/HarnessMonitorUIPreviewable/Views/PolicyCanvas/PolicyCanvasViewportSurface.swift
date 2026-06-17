import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private struct PolicyCanvasViewportSurfaceSnapshot: Equatable, Sendable {
  let documentIdentity: PolicyCanvasViewportSurfaceDocumentIdentity?
  let simulationIdentity: PolicyCanvasViewportSurfaceSimulationIdentity?
  let auditIdentity: PolicyCanvasViewportSurfaceAuditIdentity?
  let algorithmSelection: PolicyCanvasAlgorithmSelection
  let policyDisplayName: String?
}

private struct PolicyCanvasViewportSurfaceDocumentIdentity: Equatable, Sendable {
  let schemaVersion: UInt16
  let revision: UInt64
  let mode: TaskBoardPolicyPipelineMode
  let nodeCount: Int
  let edgeCount: Int
  let groupCount: Int
  let firstNodeID: String?
  let lastNodeID: String?
  let firstEdgeID: String?
  let lastEdgeID: String?
  let layoutNodeCount: Int
  let routingHintCount: Int
  let policyTraceCount: Int
  let lastPolicyTraceID: String?

  init(_ document: TaskBoardPolicyPipelineDocument) {
    schemaVersion = document.schemaVersion
    revision = document.revision
    mode = document.mode
    nodeCount = document.nodes.count
    edgeCount = document.edges.count
    groupCount = document.groups.count
    firstNodeID = document.nodes.first?.id.rawValue
    lastNodeID = document.nodes.last?.id.rawValue
    firstEdgeID = document.edges.first?.id.rawValue
    lastEdgeID = document.edges.last?.id.rawValue
    layoutNodeCount = document.layout.nodes.count
    routingHintCount = document.layout.routingHints.count
    policyTraceCount = document.policyTraceIds.count
    lastPolicyTraceID = document.policyTraceIds.last
  }
}

private struct PolicyCanvasViewportSurfaceSimulationIdentity: Equatable, Sendable {
  let revision: UInt64
  let traceID: String
  let simulatedAt: String
  let succeeded: Bool
  let decisionCount: Int
  let policyTraceCount: Int
  let lastPolicyTraceID: String?

  init(_ simulation: TaskBoardPolicyPipelineSimulationResult) {
    revision = simulation.revision
    traceID = simulation.traceId
    simulatedAt = simulation.simulatedAt
    succeeded = simulation.succeeded
    decisionCount = simulation.decisions.count
    policyTraceCount = simulation.policyTraceIds.count
    lastPolicyTraceID = simulation.policyTraceIds.last
  }
}

private struct PolicyCanvasViewportSurfaceAuditIdentity: Equatable, Sendable {
  let activeRevision: UInt64
  let mode: TaskBoardPolicyPipelineMode
  let latestTraceID: String?
  let latestSimulationTraceID: String?

  init(_ audit: TaskBoardPolicyPipelineAuditSummary) {
    activeRevision = audit.activeRevision
    mode = audit.mode
    latestTraceID = audit.latestTraceId
    latestSimulationTraceID = audit.latestSimulation?.traceId
  }
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
  let showsQualityInspection: Bool
  /// When true the surface re-runs the automatic layout engine on appear and after
  /// every document load, so it reflects the algorithms rather than the
  /// document's authored seed coordinates. The Policy Canvas Lab sets this; the
  /// shipping canvas (PolicyCanvasView) keeps authored layouts and never does.
  let forcesEngineLayout: Bool
  /// Monotonic token the host bumps to request a manual reformat (toolbar
  /// button). Every change re-runs the automatic layout engine.
  let reformatRequest: Int
  /// Display name shown on the single container group that wraps the graph.
  let policyDisplayName: String?

  @State private var viewModel: PolicyCanvasViewModel
  @State private var appliedSnapshot: PolicyCanvasViewportSurfaceSnapshot?
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
    showsQualityInspection: Bool = false,
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
    self.showsQualityInspection = showsQualityInspection
    self.forcesEngineLayout = forcesEngineLayout
    self.reformatRequest = reformatRequest
    self.policyDisplayName = policyDisplayName
    _viewModel = State(
      initialValue: PolicyCanvasViewModel.liveStartupState(
        document: nil,
        simulation: nil,
        audit: nil,
        activeCanvasId: nil,
        algorithmSelection: algorithmSelection,
        policyGroupTitle: policyDisplayName
      )
    )
  }

  private var snapshot: PolicyCanvasViewportSurfaceSnapshot {
    PolicyCanvasViewportSurfaceSnapshot(
      documentIdentity: document.map(PolicyCanvasViewportSurfaceDocumentIdentity.init),
      simulationIdentity: simulation.map(PolicyCanvasViewportSurfaceSimulationIdentity.init),
      auditIdentity: audit.map(PolicyCanvasViewportSurfaceAuditIdentity.init),
      algorithmSelection: algorithmSelection,
      policyDisplayName: policyDisplayName
    )
  }

  private var surfaceForcesEngineLayout: Bool {
    forcesEngineLayout
      || ProcessInfo.processInfo.environment[
        "HARNESS_MONITOR_POLICY_CANVAS_LAB_FORCE_REFLOW"
      ] == "1"
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
      showsEdgeLegend: showsEdgeLegend,
      showsQualityInspection: showsQualityInspection
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
    .environment(\.policyCanvasReducedMotion, systemReduceMotion)
    .task(id: snapshot) {
      // The fixture/document-load path renders the document's authored positions
      // without running the auto-arrange engine, so a load shows the saved seeds
      // rather than the algorithm output. The lab wants the automatic engine's
      // placement, so force an unconstrained reflow on appear. The env override
      // keeps the agent capture script working even when a caller leaves
      // forcesEngineLayout off. The shipping canvas uses PolicyCanvasView, not
      // this surface, and keeps its authored layout.
      applySurfaceSnapshot(snapshot)
    }
    .onChange(of: reformatRequest, initial: false) { _, _ in
      viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
    }
  }

  @MainActor
  private func applySurfaceSnapshot(_ newSnapshot: PolicyCanvasViewportSurfaceSnapshot) {
    let oldSnapshot = appliedSnapshot
    guard oldSnapshot != newSnapshot else {
      return
    }
    appliedSnapshot = newSnapshot

    viewModel.algorithmSelection = newSnapshot.algorithmSelection
    viewModel.policyGroupTitle = newSnapshot.policyDisplayName

    if oldSnapshot?.documentIdentity != newSnapshot.documentIdentity {
      viewModel.applyDocument(
        document: document,
        simulation: simulation,
        audit: audit,
        forceDocumentReload: true
      )
      if surfaceForcesEngineLayout {
        requestForcedEngineLayoutIfNeeded()
      }
    } else {
      viewModel.loadIfChanged(
        document: document,
        simulation: simulation,
        audit: audit
      )
    }
  }

  @MainActor
  private func requestForcedEngineLayoutIfNeeded() {
    guard viewModel.precomputedRoutes == nil else {
      return
    }
    viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
  }
}
