import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Persisted visibility of the lab graph-quality metrics panel. Off by default,
/// so the shipping canvas (which has no toggle) never computes the report.
public enum PolicyCanvasQualityMetricsDefaults {
  public static let isVisibleKey = "policyCanvas.qualityMetrics.isVisible"
  public static let isVisibleDefault = false
}

/// Inputs to one graph-quality measurement: a laid-out graph plus the projected
/// routes the canvas actually draws, so the report measures exactly what is on
/// screen.
struct PolicyCanvasQualityWorkerInput: Equatable, Sendable {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
}

/// Computes the deterministic graph-quality report off the main actor and caches
/// the last result by input. The report is O(n^2) over route segments, so the
/// metrics panel runs it here and only when the routed graph changes - never on
/// the render path.
actor PolicyCanvasQualityWorker {
  private var cachedInput: PolicyCanvasQualityWorkerInput?
  private var cachedOutput = PolicyCanvasGraphQualityReport.empty

  func compute(input: PolicyCanvasQualityWorkerInput) -> PolicyCanvasGraphQualityReport {
    guard input != cachedInput else {
      return cachedOutput
    }
    let output = policyCanvasMeasureGraphQuality(
      nodes: input.nodes,
      groups: input.groups,
      edges: input.edges,
      routes: input.routes,
      labelPositions: input.labelPositions,
      portMarkerLayout: input.portMarkerLayout
    )
    cachedInput = input
    cachedOutput = output
    return output
  }
}

/// Re-run trigger for the measurement task: recompute when the panel is toggled
/// or when the routed graph changes (the route signature is a cheap checksum).
private struct PolicyCanvasQualityInspectionKey: Equatable {
  let enabled: Bool
  let signature: PolicyCanvasRouteWorkerOutputSignature
}

/// Drives the lab metrics panel: measures the routed graph off-main whenever it
/// changes (only while enabled) and overlays the panel in the top-trailing
/// corner. Reads the same routes the canvas renders, so the counts match the
/// picture. Costs nothing when the panel is hidden.
struct PolicyCanvasQualityInspectionModifier: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  let routeSignature: PolicyCanvasRouteWorkerOutputSignature
  let isEnabled: Bool
  let resolvedCanvasColorScheme: ColorScheme?

  @State private var worker = PolicyCanvasQualityWorker()

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topTrailing) {
        if isEnabled, let report = viewModel.qualityInspectionReport {
          PolicyCanvasQualityMetricsPanel(
            report: report,
            hoveredCategories: Set(viewModel.hoveredQualityMarks.map(\.category))
          )
          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
          .padding(14)
          .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.18), value: isEnabled)
      .task(
        id: PolicyCanvasQualityInspectionKey(
          enabled: isEnabled,
          signature: routeSignature
        )
      ) {
        guard isEnabled else {
          viewModel.qualityInspectionReport = nil
          viewModel.qualityReportGeneration += 1
          return
        }
        let input = PolicyCanvasQualityWorkerInput(
          nodes: viewModel.nodes,
          groups: viewModel.groups,
          edges: viewModel.edges,
          routes: routes,
          labelPositions: labelPositions,
          portMarkerLayout: portMarkerLayout
        )
        let computed = await worker.compute(input: input)
        guard !Task.isCancelled, viewModel.qualityInspectionReport != computed else {
          return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
          viewModel.qualityInspectionReport = computed
        }
        viewModel.qualityReportGeneration += 1
      }
  }
}

/// The routed-graph snapshot the metrics panel measures: the projected routes
/// the canvas draws plus the signature that gates recomputation.
struct PolicyCanvasQualityInspectionInputs {
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  let routeSignature: PolicyCanvasRouteWorkerOutputSignature
}

extension View {
  /// Attach the lab graph-quality metrics panel, measured from `inputs.routes`
  /// and recomputed whenever the route signature changes.
  func policyCanvasQualityInspection(
    viewModel: PolicyCanvasViewModel,
    inputs: PolicyCanvasQualityInspectionInputs,
    isEnabled: Bool,
    resolvedCanvasColorScheme: ColorScheme?
  ) -> some View {
    modifier(
      PolicyCanvasQualityInspectionModifier(
        viewModel: viewModel,
        routes: inputs.routes,
        labelPositions: inputs.labelPositions,
        portMarkerLayout: inputs.portMarkerLayout,
        routeSignature: inputs.routeSignature,
        isEnabled: isEnabled,
        resolvedCanvasColorScheme: resolvedCanvasColorScheme
      )
    )
  }
}
