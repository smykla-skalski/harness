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

private struct PolicyCanvasViewportSurfaceRenderKey: Equatable {
  let snapshot: PolicyCanvasViewportSurfaceSnapshot
  let fontScale: CGFloat
}

private struct PolicyCanvasViewportSurfaceDocumentIdentity: Equatable, Sendable {
  let schemaVersion: UInt16
  let revision: UInt64
  let mode: PolicyPipelineMode
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

  init(_ document: PolicyPipelineDocument) {
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

  init(_ simulation: PolicyPipelineSimulationResult) {
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
  let mode: PolicyPipelineMode
  let latestTraceID: String?
  let latestSimulationTraceID: String?

  init(_ audit: PolicyPipelineAuditSummary) {
    activeRevision = audit.activeRevision
    mode = audit.mode
    latestTraceID = audit.latestTraceId
    latestSimulationTraceID = audit.latestSimulation?.traceId
  }
}

public struct PolicyCanvasViewportSurface: View {
  let document: PolicyPipelineDocument?
  let simulation: PolicyPipelineSimulationResult?
  let audit: PolicyPipelineAuditSummary?
  let algorithmSelection: PolicyCanvasAlgorithmSelection
  let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
  let canvasColorSchemeOverride: ColorScheme?
  let showsEdgeLegend: Bool
  let resizeZoomBehavior: PolicyCanvasViewportResizeZoomBehavior
  let showsQualityInspection: Bool
  /// When true the surface re-runs the same forced reformat route plan production
  /// uses before first paint. The Policy Canvas Lab sets this so it can work on
  /// the production Reformat shape without compiling the full app; the shipping
  /// canvas (PolicyCanvasView) keeps authored layouts until Reformat is invoked.
  let forcesEngineLayout: Bool
  /// Monotonic token the host bumps to request a manual reformat (toolbar
  /// button). Every change re-runs the automatic layout engine.
  let reformatRequest: Int
  /// Display name shown on the single container group that wraps the graph.
  let policyDisplayName: String?

  @State private var viewModel: PolicyCanvasViewModel
  @State private var routeSeed: PolicyCanvasViewportRouteSeed?
  @State private var appliedSnapshot: PolicyCanvasViewportSurfaceSnapshot?
  @AccessibilityFocusState private var focusedComponentState: PolicyCanvasSelection?
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion
  @Environment(\.fontScale)
  private var fontScale

  @MainActor
  public init(
    document: PolicyPipelineDocument?,
    simulation: PolicyPipelineSimulationResult?,
    audit: PolicyPipelineAuditSummary?,
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

  private var renderKey: PolicyCanvasViewportSurfaceRenderKey {
    PolicyCanvasViewportSurfaceRenderKey(snapshot: snapshot, fontScale: fontScale)
  }

  public var body: some View {
    viewportContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
      .environment(\.policyCanvasReducedMotion, systemReduceMotion)
      .task(id: renderKey) {
        // The fixture/document-load path renders the document's authored positions
        // without running the auto-arrange engine, so a load shows the saved seeds
        // rather than the algorithm output. The lab wants the automatic engine's
        // placement, so force an unconstrained reflow on appear. The env override
        // keeps the agent capture script working even when a caller leaves
        // forcesEngineLayout off. The shipping canvas uses PolicyCanvasView, not
        // this surface, and keeps its authored layout.
        await applySurfaceSnapshot(renderKey.snapshot, fontScale: renderKey.fontScale)
      }
      .onChange(of: reformatRequest, initial: false) { _, _ in
        viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
      }
  }

  private var holdsViewportUntilFinalRoute: Bool {
    surfaceForcesEngineLayout
      && document?.nodes.isEmpty == false
      && appliedSnapshot != snapshot
  }

  @ViewBuilder private var viewportContent: some View {
    if holdsViewportUntilFinalRoute {
      PolicyCanvasPendingFinalRouteSurface()
        .policyCanvasResolvedThemeScope(canvasColorSchemeOverride)
    } else {
      viewport
    }
  }

  private var viewport: some View {
    PolicyCanvasViewport(
      viewModel: viewModel,
      focusedComponent: $focusedComponentState,
      suppressesSceneStorage: true,
      storedPipelineStateRaw: "",
      resizeZoomBehavior: resizeZoomBehavior,
      minimapCenteringModeOverride: minimapCenteringModeOverride,
      canvasColorSchemeOverride: canvasColorSchemeOverride,
      showsEdgeLegend: showsEdgeLegend,
      showsQualityInspection: showsQualityInspection,
      routeSeed: routeSeed,
      onFinalRouteOutputReady: markPolicyCanvasLabReadyIfNeeded
    )
  }

  @MainActor
  private func applySurfaceSnapshot(
    _ newSnapshot: PolicyCanvasViewportSurfaceSnapshot,
    fontScale: CGFloat
  ) async {
    let oldSnapshot = appliedSnapshot
    guard oldSnapshot != newSnapshot else {
      return
    }
    if surfaceForcesEngineLayout, oldSnapshot?.documentIdentity != newSnapshot.documentIdentity {
      await applyForcedEngineSurfaceSnapshot(newSnapshot, fontScale: fontScale)
      return
    }
    appliedSnapshot = newSnapshot
    routeSeed = nil

    viewModel.algorithmSelection = newSnapshot.algorithmSelection
    viewModel.policyGroupTitle = newSnapshot.policyDisplayName

    if oldSnapshot?.documentIdentity != newSnapshot.documentIdentity {
      viewModel.applyDocument(
        document: document,
        simulation: simulation,
        audit: audit,
        forceDocumentReload: true
      )
    } else {
      viewModel.loadIfChanged(
        document: document,
        simulation: simulation,
        audit: audit
      )
    }
  }

  @MainActor
  private func applyForcedEngineSurfaceSnapshot(
    _ newSnapshot: PolicyCanvasViewportSurfaceSnapshot,
    fontScale: CGFloat
  ) async {
    let stagedViewModel = PolicyCanvasViewModel.liveStartupState(
      document: document,
      simulation: simulation,
      audit: audit,
      algorithmSelection: newSnapshot.algorithmSelection,
      policyGroupTitle: newSnapshot.policyDisplayName
    )
    guard !stagedViewModel.isEmpty else {
      guard !Task.isCancelled else {
        return
      }
      appliedSnapshot = newSnapshot
      routeSeed = nil
      viewModel = stagedViewModel
      return
    }
    guard
      let plan = await policyCanvasAtomicReflowRoutePlan(
        viewModel: stagedViewModel,
        preserveManualAnchors: false,
        force: true,
        fontScale: fontScale,
        routeWorker: PolicyCanvasRouteWorker(),
        routesCurrentGraphWhenUnchanged: true
      )
    else {
      return
    }
    guard !Task.isCancelled else {
      return
    }
    if plan.appliesLayoutChange {
      stagedViewModel.commitPlannedReflowGraph(
        plan.graph,
        preserveManualAnchors: false,
        force: true,
        requestsRouteComputation: false
      )
    }
    let routeKey = policyCanvasRouteWorkerKey(
      viewModel: stagedViewModel,
      nodes: stagedViewModel.nodes,
      groups: stagedViewModel.groups,
      edges: stagedViewModel.edges,
      fontScale: fontScale
    )
    let seedID =
      "\(newSnapshot.documentIdentity?.lastPolicyTraceID ?? "nil")|"
      + "\(routeKey.graphGeneration)|\(routeKey.fontScale)"
    viewModel = stagedViewModel
    routeSeed = PolicyCanvasViewportRouteSeed(
      id: seedID,
      routeKey: routeKey,
      pipelineIdentity: stagedViewModel.pipelineIdentity,
      output: plan.output,
      nodePositionsByID: policyCanvasNodePositionsByID(stagedViewModel.nodes)
    )
    appliedSnapshot = newSnapshot
  }

  @MainActor
  private func markPolicyCanvasLabReadyIfNeeded() {
    guard
      let readyPath = ProcessInfo.processInfo.environment[
        "HARNESS_MONITOR_POLICY_LAB_READY_FILE"
      ],
      !readyPath.isEmpty
    else {
      return
    }
    try? "ready\n".write(toFile: readyPath, atomically: true, encoding: .utf8)
  }
}

private struct PolicyCanvasPendingFinalRouteSurface: View {
  var body: some View {
    PolicyCanvasBackgroundSurface()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
