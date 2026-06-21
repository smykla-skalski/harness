import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

private let policyCanvasSelectiveRerouteSampleIDs = [
  "minimal", "linear", "branching", "default", "multi-group",
  "extreme", "extreme-braid", "extreme-galaxy",
]

/// A node drag re-routes only the edges incident to the moved node (libavoid-style
/// `SelectiveReroute`) instead of reconverging the whole graph every gesture tick.
/// These guard the two properties that keep that fast path correct: the drag and
/// the post-drop recompute produce identical geometry (nothing snaps on release),
/// and the incident edges actually follow the node.
@MainActor
struct PolicyCanvasSelectiveRerouteTests {
  private func loadedViewModel(_ sampleID: String) -> (PolicyCanvasViewModel, PolicyCanvasNode)? {
    guard let sample = PolicyCanvasLabSamples.sample(id: sampleID) else { return nil }
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    guard let moved = viewModel.nodes.first else { return nil }
    return (viewModel, moved)
  }

  private func input(
    nodes: [PolicyCanvasNode],
    viewModel: PolicyCanvasViewModel
  ) -> PolicyCanvasRouteWorkerInput {
    // A drag tick clears the layout-engine hints/precomputed seed, exactly as
    // `bumpLayoutGeneration` does, so the worker keys on bare geometry.
    PolicyCanvasRouteWorkerInput(
      nodes: nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: nil,
      precomputedRoutes: nil,
      algorithmSelection: .referenceRouting
    )
  }

  private func geometry(_ routes: [String: PolicyCanvasEdgeRoute]) -> [String: [CGPoint]] {
    routes.mapValues(\.points)
  }

  @Test("a drag tick and the post-drop recompute produce identical geometry", arguments: policyCanvasSelectiveRerouteSampleIDs)
  func dragAndDropAgree(sampleID: String) async throws {
    guard let (viewModel, moved) = loadedViewModel(sampleID) else { return }
    let baseline = await PolicyCanvasRouteWorker().compute(
      input: input(nodes: viewModel.nodes, viewModel: viewModel)
    )
    var moved2 = viewModel.nodes
    moved2[0].position.x += 80
    moved2[0].position.y += 60
    let movedInput = input(nodes: moved2, viewModel: viewModel)

    // The last drag tick re-routes against the previous committed output.
    let dragTick = await PolicyCanvasRouteWorker().computeSelective(
      input: movedInput, movedNodeIDs: [moved.id], previous: baseline
    )
    // The drop re-runs the selective recompute against the tick's own output; it
    // must reproduce the tick byte-for-byte so releasing the node changes nothing.
    let drop = await PolicyCanvasRouteWorker().computeSelective(
      input: movedInput, movedNodeIDs: [moved.id], previous: dragTick
    )
    #expect(
      geometry(dragTick.routes) == geometry(drop.routes),
      "\(sampleID): geometry changed between the drag tick and the post-drop recompute"
    )
  }

  @Test("selective reroute moves the incident edges to follow the node", arguments: policyCanvasSelectiveRerouteSampleIDs)
  func incidentEdgesFollowMovedNode(sampleID: String) async throws {
    guard let (viewModel, moved) = loadedViewModel(sampleID) else { return }
    let incident = viewModel.edges.filter {
      $0.source.nodeID == moved.id || $0.target.nodeID == moved.id
    }
    guard !incident.isEmpty else { return }
    let baseline = await PolicyCanvasRouteWorker().compute(
      input: input(nodes: viewModel.nodes, viewModel: viewModel)
    )
    var moved2 = viewModel.nodes
    moved2[0].position.x += 80
    moved2[0].position.y += 60
    let selective = await PolicyCanvasRouteWorker().computeSelective(
      input: input(nodes: moved2, viewModel: viewModel),
      movedNodeIDs: [moved.id],
      previous: baseline
    )
    let followed = incident.contains { edge in
      baseline.routes[edge.id]?.points != selective.routes[edge.id]?.points
    }
    #expect(followed, "\(sampleID): no incident edge moved after the node was dragged 80x60")
  }

  @Test("an empty moved set falls back to a full route", arguments: policyCanvasSelectiveRerouteSampleIDs)
  func emptyMovedSetRoutesFully(sampleID: String) async throws {
    guard let (viewModel, _) = loadedViewModel(sampleID) else { return }
    let full = await PolicyCanvasRouteWorker().compute(
      input: input(nodes: viewModel.nodes, viewModel: viewModel)
    )
    let selective = await PolicyCanvasRouteWorker().computeSelective(
      input: input(nodes: viewModel.nodes, viewModel: viewModel),
      movedNodeIDs: [],
      previous: .empty
    )
    #expect(geometry(full.routes) == geometry(selective.routes))
  }
}
