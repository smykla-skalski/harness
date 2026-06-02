import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Wave 4M P45: locks the body-local `portAnchors(for:)` batch lookup
/// against the per-edge `portAnchor(for:)` calls it replaces in
/// `PolicyCanvasEdgeLayer` / `PolicyCanvasEdgeLabelLayer`. The batch path
/// must return the same anchor for every endpoint the per-edge path would
/// resolve, and nil for endpoints the per-edge path would skip — anything
/// less drifts the edge stroke from the port it claims to render between.
@Suite("Policy canvas port anchor cache")
@MainActor
struct PolicyCanvasPortAnchorCacheTests {
  @Test("empty edges return an empty anchor dictionary")
  func emptyEdgesReturnEmptyDictionary() {
    let viewModel = PolicyCanvasViewModel.sample()
    let result = viewModel.portAnchors(for: [])
    #expect(result.isEmpty)
  }

  @Test("batch lookup matches per-edge lookup on the default sample graph")
  func batchMatchesPerEdgeOnSampleGraph() {
    let viewModel = PolicyCanvasViewModel.sample()
    let batch = viewModel.portAnchors(for: viewModel.edges)

    for edge in viewModel.edges {
      let perEdgeSource = viewModel.portAnchor(for: edge.source)
      let perEdgeTarget = viewModel.portAnchor(for: edge.target)
      #expect(batch[edge.source] == perEdgeSource)
      #expect(batch[edge.target] == perEdgeTarget)
    }
  }

  @Test("batch lookup matches per-edge lookup after a node drag shifts positions")
  func batchMatchesPerEdgeAfterDrag() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.dragNode("risk-score", translation: CGSize(width: 120, height: 80))
    viewModel.endNodeDrag("risk-score", translation: CGSize(width: 120, height: 80))

    let batch = viewModel.portAnchors(for: viewModel.edges)
    for edge in viewModel.edges {
      #expect(batch[edge.source] == viewModel.portAnchor(for: edge.source))
      #expect(batch[edge.target] == viewModel.portAnchor(for: edge.target))
    }
  }

  @Test("dropped edges with missing nodes omit anchors from the cache")
  func missingNodeEndpointsAreOmitted() {
    let viewModel = PolicyCanvasViewModel.sample()
    let phantom = PolicyCanvasEdge(
      id: "phantom-edge",
      source: PolicyCanvasPortEndpoint(
        nodeID: "no-such-node",
        portID: "output-event",
        kind: .output
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: "still-no-such-node",
        portID: "input-event",
        kind: .input
      ),
      label: ""
    )

    let batch = viewModel.portAnchors(for: [phantom])

    // Per-edge resolver returns nil for both endpoints; the batch dict must
    // omit them so callers can gate on `dict[endpoint] != nil` identically.
    #expect(batch[phantom.source] == nil)
    #expect(batch[phantom.target] == nil)
    #expect(batch.isEmpty)
  }

  @Test("partial-resolve edge keeps the resolvable endpoint in the cache")
  func partialResolveKeepsValidEndpoint() {
    let viewModel = PolicyCanvasViewModel.sample()
    let realSource = PolicyCanvasPortEndpoint(
      nodeID: "policy-source",
      portID: "output-event",
      kind: .output
    )
    let missingTarget = PolicyCanvasPortEndpoint(
      nodeID: "no-such-node",
      portID: "input-event",
      kind: .input
    )
    let mixed = PolicyCanvasEdge(
      id: "mixed-edge",
      source: realSource,
      target: missingTarget,
      label: ""
    )

    let batch = viewModel.portAnchors(for: [mixed])
    #expect(batch[realSource] == viewModel.portAnchor(for: realSource))
    #expect(batch[missingTarget] == nil)
  }

  @Test("repeated endpoints across edges resolve to the same anchor")
  func repeatedEndpointsResolveOnce() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let source = viewModel.edges.first?.source else {
      Issue.record("expected at least one edge in sample")
      return
    }

    // Two synthetic edges that share the same source endpoint should yield
    // the same anchor under both calls (idempotent dict write).
    let dup = PolicyCanvasEdge(
      id: "dup-edge",
      source: source,
      target: PolicyCanvasPortEndpoint(
        nodeID: "review-gate",
        portID: "input-policy",
        kind: .input
      ),
      label: ""
    )

    let batch = viewModel.portAnchors(for: viewModel.edges + [dup])
    let perEdge = viewModel.portAnchor(for: source)
    #expect(batch[source] == perEdge)
  }

  @Test("loaded document anchors match per-edge resolution across all edges")
  func loadedDocumentAnchorsMatch() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)

    let batch = viewModel.portAnchors(for: viewModel.edges)
    #expect(!batch.isEmpty)
    for edge in viewModel.edges {
      #expect(batch[edge.source] == viewModel.portAnchor(for: edge.source))
      #expect(batch[edge.target] == viewModel.portAnchor(for: edge.target))
    }
  }
}
