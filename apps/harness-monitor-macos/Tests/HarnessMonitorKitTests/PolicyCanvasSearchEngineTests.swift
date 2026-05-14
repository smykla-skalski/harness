import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

/// Coverage for the canvas search engine's ranking, filtering, and perf
/// envelope. The engine is pure-value, so these tests construct lightweight
/// fixtures directly rather than going through `PolicyCanvasViewModel`.
@Suite("Policy canvas search engine")
struct PolicyCanvasSearchEngineTests {
  @Test("empty query returns no hits")
  func emptyQueryReturnsNothing() {
    let engine = PolicyCanvasSearchEngine()
    let hits = engine.search(
      query: "",
      nodes: fixtureNodes(),
      edges: fixtureEdges(),
      groups: fixtureGroups()
    )
    #expect(hits.isEmpty)
  }

  @Test("whitespace-only query returns no hits")
  func whitespaceQueryReturnsNothing() {
    let engine = PolicyCanvasSearchEngine()
    let hits = engine.search(
      query: "   \n\t",
      nodes: fixtureNodes(),
      edges: fixtureEdges(),
      groups: fixtureGroups()
    )
    #expect(hits.isEmpty)
  }

  @Test("exact title match ranks first")
  func exactTitleMatchRanksFirst() {
    let engine = PolicyCanvasSearchEngine()
    let hits = engine.search(
      query: "Risk score",
      nodes: fixtureNodes(),
      edges: [],
      groups: []
    )
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
    let engine = PolicyCanvasSearchEngine()
    let nodes = [
      PolicyCanvasSearchableNode(id: "a", title: "Promote release", kindName: "decision"),
      PolicyCanvasSearchableNode(id: "b", title: "Bulk promote", kindName: "decision"),
    ]
    let hits = engine.search(query: "promote", nodes: nodes, edges: [], groups: [])
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
    let engine = PolicyCanvasSearchEngine()
    let nodes = [
      PolicyCanvasSearchableNode(id: "a", title: "Eligibility check", kindName: "condition"),
      PolicyCanvasSearchableNode(id: "b", title: "Other", kindName: "condition"),
    ]
    let hits = engine.search(query: "condition", nodes: nodes, edges: [], groups: [])
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
    let engine = PolicyCanvasSearchEngine()
    let nodes = [
      PolicyCanvasSearchableNode(id: "a", title: "Übergabe", kindName: "review")
    ]
    let hits = engine.search(query: "ubergabe", nodes: nodes, edges: [], groups: [])
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
    let engine = PolicyCanvasSearchEngine()
    let nodes = [
      PolicyCanvasSearchableNode(id: "a", title: "Policy Intake", kindName: "source")
    ]
    let hits = engine.search(query: "POLICY", nodes: nodes, edges: [], groups: [])
    #expect(hits.count == 1)
    if case .node(_, _, _, let score) = hits[0] {
      #expect(score == 75)
    }
  }

  @Test("edge label match returns an edge hit")
  func edgeLabelMatch() {
    let engine = PolicyCanvasSearchEngine()
    let edges = [
      PolicyCanvasSearchableEdge(id: "edge-1", label: "needs review")
    ]
    let hits = engine.search(query: "review", nodes: [], edges: edges, groups: [])
    #expect(hits.count == 1)
    if case .edge(let id, _, _, _) = hits[0] {
      #expect(id == "edge-1")
    } else {
      Issue.record("expected edge hit")
    }
  }

  @Test("group title match returns a group hit")
  func groupTitleMatch() {
    let engine = PolicyCanvasSearchEngine()
    let groups = [
      PolicyCanvasSearchableGroup(id: "group-1", title: "Evaluation")
    ]
    let hits = engine.search(query: "eval", nodes: [], edges: [], groups: groups)
    #expect(hits.count == 1)
    if case .group(let id, _, _, _) = hits[0] {
      #expect(id == "group-1")
    } else {
      Issue.record("expected group hit")
    }
  }

  @Test("filter restricts hits to enabled types")
  func filterRestrictsToEnabledTypes() {
    let engine = PolicyCanvasSearchEngine()
    let nodes = [PolicyCanvasSearchableNode(id: "n", title: "Match node", kindName: "source")]
    let edges = [PolicyCanvasSearchableEdge(id: "e", label: "Match edge")]
    let groups = [PolicyCanvasSearchableGroup(id: "g", title: "Match group")]
    let onlyEdges = PolicyCanvasSearchFilter(
      includeNodes: false,
      includeEdges: true,
      includeGroups: false
    )
    let hits = engine.search(
      query: "match",
      nodes: nodes,
      edges: edges,
      groups: groups,
      filter: onlyEdges
    )
    #expect(hits.count == 1)
    if case .edge = hits[0] {
      // ok
    } else {
      Issue.record("expected an edge hit only")
    }
  }

  @Test("ties on score sort by stable id order")
  func tiesSortByID() {
    let engine = PolicyCanvasSearchEngine()
    let nodes = [
      PolicyCanvasSearchableNode(id: "zeta", title: "Match here", kindName: "source"),
      PolicyCanvasSearchableNode(id: "alpha", title: "Match here", kindName: "source"),
      PolicyCanvasSearchableNode(id: "mu", title: "Match here", kindName: "source"),
    ]
    let hits = engine.search(query: "match", nodes: nodes, edges: [], groups: [])
    #expect(hits.count == 3)
    // All same prefix-tier score; tie-break alphabetic on id.
    if case .node(let id0, _, _, _) = hits[0] { #expect(id0 == "alpha") }
    if case .node(let id1, _, _, _) = hits[1] { #expect(id1 == "mu") }
    if case .node(let id2, _, _, _) = hits[2] { #expect(id2 == "zeta") }
  }

  @Test("match against 200-node graph stays under 5ms")
  func twoHundredNodeSearchUnderFiveMillis() {
    let engine = PolicyCanvasSearchEngine()
    let nodes: [PolicyCanvasSearchableNode] = (0..<200).map { index in
      PolicyCanvasSearchableNode(
        id: "node-\(index)",
        title: "Policy node \(index)",
        kindName: index % 2 == 0 ? "condition" : "review"
      )
    }
    let start = Date()
    let hits = engine.search(query: "policy", nodes: nodes, edges: [], groups: [])
    let elapsed = Date().timeIntervalSince(start)
    #expect(hits.count == 200)
    // 5ms ceiling on M-series; double it to 10ms for CI headroom — engine
    // is well inside this on local runs.
    #expect(elapsed < 0.010)
  }

  // MARK: - Fixtures

  private func fixtureNodes() -> [PolicyCanvasSearchableNode] {
    [
      PolicyCanvasSearchableNode(id: "policy-source", title: "Policy intake", kindName: "source"),
      PolicyCanvasSearchableNode(id: "risk-score", title: "Risk score", kindName: "condition"),
      PolicyCanvasSearchableNode(id: "review-gate", title: "Review gate", kindName: "review"),
      PolicyCanvasSearchableNode(id: "context-map", title: "Context map", kindName: "transform"),
      PolicyCanvasSearchableNode(
        id: "promote-release", title: "Promote release", kindName: "decision"),
    ]
  }

  private func fixtureEdges() -> [PolicyCanvasSearchableEdge] {
    [
      PolicyCanvasSearchableEdge(id: "edge-intake-risk", label: "normalize"),
      PolicyCanvasSearchableEdge(id: "edge-risk-review", label: "needs review"),
    ]
  }

  private func fixtureGroups() -> [PolicyCanvasSearchableGroup] {
    [
      PolicyCanvasSearchableGroup(id: "group-intake", title: "Input contract"),
      PolicyCanvasSearchableGroup(id: "group-evaluation", title: "Evaluation"),
    ]
  }
}
