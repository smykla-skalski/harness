import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

/// Coverage for `PolicyCanvasViewModel.searchHits(query:)`. The search is
/// implemented as a view-model method (not a separate engine) so every test
/// drives it through a real `PolicyCanvasViewModel` fixture built from the
/// existing `PolicyCanvasNode` / `PolicyCanvasEdge` / `PolicyCanvasGroup`
/// shapes the production canvas uses.
@MainActor
@Suite("Policy canvas search")
struct PolicyCanvasSearchTests {
  @Test("empty query returns no hits")
  func emptyQueryReturnsNothing() {
    let viewModel = makeViewModel()
    let hits = viewModel.searchHits(query: "")
    #expect(hits.isEmpty)
  }

  @Test("whitespace-only query returns no hits")
  func whitespaceQueryReturnsNothing() {
    let viewModel = makeViewModel()
    let hits = viewModel.searchHits(query: "   \n\t")
    #expect(hits.isEmpty)
  }

  @Test("exact title match ranks first")
  func exactTitleMatchRanksFirst() {
    let viewModel = makeViewModel()
    let hits = viewModel.searchHits(query: "Risk score")
    guard let first = hits.first else {
      Issue.record("expected at least one hit")
      return
    }
    if case .node(let id, _, _, let score) = first {
      #expect(id == "risk-score")
      #expect(score == 100)
    } else {
      Issue.record("expected node hit, got \(first)")
    }
  }

  @Test("prefix match beats substring match")
  func prefixBeatsSubstring() {
    let viewModel = makeViewModel(
      nodes: [
        node(id: "a", title: "Promote release", kind: .decision),
        node(id: "b", title: "Bulk promote", kind: .decision),
      ]
    )
    let hits = viewModel.searchHits(query: "promote")
    #expect(hits.count == 2)
    if case .node(let id, _, _, _) = hits[0] {
      #expect(id == "a")
    } else {
      Issue.record("expected prefix match to rank first")
    }
    if case .node(_, _, _, let score) = hits[0] {
      #expect(score == 75)
    }
    if case .node(_, _, _, let score) = hits[1] {
      #expect(score == 50)
    }
  }

  @Test("kind-name match scores below substring title match")
  func kindNameMatchRanksBelowSubstring() {
    // Both titles are unrelated to "condition"; only the kind matches.
    let viewModel = makeViewModel(
      nodes: [
        node(id: "a", title: "Eligibility check", kind: .condition),
        node(id: "b", title: "Other", kind: .condition),
      ]
    )
    let hits = viewModel.searchHits(query: "condition")
    #expect(hits.count == 2)
    if case .node(_, _, _, let score) = hits[0] {
      #expect(score == 25)
    }
    if case .node(_, _, _, let score) = hits[1] {
      #expect(score == 25)
    }
  }

  @Test("diacritic-insensitive match folds accented characters")
  func diacriticInsensitiveMatch() {
    let viewModel = makeViewModel(
      nodes: [node(id: "a", title: "Übergabe", kind: .review)]
    )
    let hits = viewModel.searchHits(query: "ubergabe")
    #expect(hits.count == 1)
    if case .node(let id, _, _, let score) = hits[0] {
      #expect(id == "a")
      #expect(score == 100)
    } else {
      Issue.record("expected diacritic-insensitive node hit")
    }
  }

  @Test("case-insensitive match works regardless of input casing")
  func caseInsensitiveMatch() {
    let viewModel = makeViewModel(
      nodes: [node(id: "a", title: "Policy Intake", kind: .source)]
    )
    let hits = viewModel.searchHits(query: "POLICY")
    #expect(hits.count == 1)
    if case .node(_, _, _, let score) = hits[0] {
      #expect(score == 75)
    }
  }

  @Test("edge label match returns an edge hit")
  func edgeLabelMatch() {
    let viewModel = makeViewModel(
      nodes: [
        node(id: "src", title: "Intake", kind: .source),
        node(id: "dst", title: "Review", kind: .review),
      ],
      edges: [
        edge(id: "edge-1", sourceNode: "src", targetNode: "dst", label: "needs review")
      ]
    )
    let hits = viewModel.searchHits(query: "needs")
    #expect(hits.count == 1)
    if case .edge(let id, _, _, _) = hits[0] {
      #expect(id == "edge-1")
    } else {
      Issue.record("expected edge hit")
    }
  }

  @Test("group title match returns a group hit")
  func groupTitleMatch() {
    let viewModel = makeViewModel(
      groups: [group(id: "group-1", title: "Evaluation")]
    )
    let hits = viewModel.searchHits(query: "eval")
    #expect(hits.count == 1)
    if case .group(let id, _, _, _) = hits[0] {
      #expect(id == "group-1")
    } else {
      Issue.record("expected group hit")
    }
  }

  @Test("ties on score sort by stable id order")
  func tiesSortByID() {
    let viewModel = makeViewModel(
      nodes: [
        node(id: "zeta", title: "Match here", kind: .source),
        node(id: "alpha", title: "Match here", kind: .source),
        node(id: "mu", title: "Match here", kind: .source),
      ]
    )
    let hits = viewModel.searchHits(query: "match")
    #expect(hits.count == 3)
    // All same prefix-tier score; tie-break alphabetic on id.
    if case .node(let id0, _, _, _) = hits[0] { #expect(id0 == "alpha") }
    if case .node(let id1, _, _, _) = hits[1] { #expect(id1 == "mu") }
    if case .node(let id2, _, _, _) = hits[2] { #expect(id2 == "zeta") }
  }

  @Test("limit caps the returned hit count")
  func limitCapsHits() {
    let nodes: [PolicyCanvasNode] = (0..<20).map { index in
      node(id: "node-\(index)", title: "Policy node \(index)", kind: .source)
    }
    let viewModel = makeViewModel(nodes: nodes)
    let hits = viewModel.searchHits(query: "policy", limit: 5)
    #expect(hits.count == 5)
  }

  @Test("hit selection maps onto the matching component kind")
  func hitSelectionPayload() {
    let viewModel = makeViewModel(
      nodes: [node(id: "n1", title: "Alpha", kind: .source)],
      edges: [
        edge(id: "e1", sourceNode: "n1", targetNode: "n1", label: "Alpha edge")
      ],
      groups: [group(id: "g1", title: "Alpha group")]
    )
    let hits = viewModel.searchHits(query: "alpha")
    #expect(hits.count == 3)
    for hit in hits {
      switch hit {
      case .node(let id, _, _, _):
        #expect(hit.selection == .node(id))
      case .edge(let id, _, _, _):
        #expect(hit.selection == .edge(id))
      case .group(let id, _, _, _):
        #expect(hit.selection == .group(id))
      }
    }
  }

  @Test("match against 200-node graph stays under 10ms")
  func twoHundredNodeSearchUnderTenMillis() {
    let nodes: [PolicyCanvasNode] = (0..<200).map { index in
      node(
        id: "node-\(index)",
        title: "Policy node \(index)",
        kind: index % 2 == 0 ? .condition : .review
      )
    }
    let viewModel = makeViewModel(nodes: nodes)
    let start = Date()
    let hits = viewModel.searchHits(query: "policy", limit: 1_000)
    let elapsed = Date().timeIntervalSince(start)
    #expect(hits.count == 200)
    // 5ms ceiling on M-series; double it to 10ms for CI headroom — well
    // inside this on local runs.
    #expect(elapsed < 0.010)
  }

  // MARK: - Fixtures

  private func makeViewModel(
    nodes: [PolicyCanvasNode] = [],
    edges: [PolicyCanvasEdge] = [],
    groups: [PolicyCanvasGroup] = []
  ) -> PolicyCanvasViewModel {
    if nodes.isEmpty, edges.isEmpty, groups.isEmpty {
      return defaultViewModel()
    }
    return PolicyCanvasViewModel(nodes: nodes, groups: groups, edges: edges)
  }

  private func defaultViewModel() -> PolicyCanvasViewModel {
    PolicyCanvasViewModel(
      nodes: [
        node(id: "policy-source", title: "Policy intake", kind: .source),
        node(id: "risk-score", title: "Risk score", kind: .condition),
        node(id: "review-gate", title: "Review gate", kind: .review),
        node(id: "context-map", title: "Context map", kind: .transform),
        node(id: "promote-release", title: "Promote release", kind: .decision),
      ],
      groups: [
        group(id: "group-intake", title: "Input contract"),
        group(id: "group-evaluation", title: "Evaluation"),
      ],
      edges: [
        edge(
          id: "edge-intake-risk",
          sourceNode: "policy-source",
          targetNode: "risk-score",
          label: "normalize"
        ),
        edge(
          id: "edge-risk-review",
          sourceNode: "risk-score",
          targetNode: "review-gate",
          label: "needs review"
        ),
      ]
    )
  }

  private func node(id: String, title: String, kind: PolicyCanvasNodeKind) -> PolicyCanvasNode {
    PolicyCanvasNode(id: id, title: title, kind: kind, position: .zero)
  }

  private func edge(
    id: String,
    sourceNode: String,
    targetNode: String,
    label: String
  ) -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: id,
      source: PolicyCanvasPortEndpoint(nodeID: sourceNode, portID: "output", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: targetNode, portID: "input", kind: .input),
      label: label
    )
  }

  private func group(id: String, title: String) -> PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: id,
      title: title,
      frame: CGRect(x: 0, y: 0, width: 240, height: 200),
      tone: .intake
    )
  }
}
