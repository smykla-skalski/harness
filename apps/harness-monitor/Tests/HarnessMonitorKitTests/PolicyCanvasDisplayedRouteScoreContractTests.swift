import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas displayed route score contract")
struct PolicyCanvasDisplayedRouteScoreContractTests {
  @Test("degenerate route scores as infinitely bad so it never wins flex selection")
  func degenerateRouteScoresAsInfinitelyBad() {
    let degenerate = PolicyCanvasEdgeRoute(points: [], labelPosition: .zero)
    let endpoint = PolicyCanvasEscapeCandidate(
      side: .trailing,
      actual: .zero,
      exit: .zero,
      routed: .zero
    )
    let context = PolicyCanvasRouteContext(
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil
    )

    let score = policyCanvasDisplayedRouteScore(
      degenerate,
      source: endpoint,
      target: endpoint,
      context: context
    )

    #expect(score == .greatestFiniteMagnitude)
  }

  @Test("single-point route also scores as infinitely bad")
  func singlePointRouteScoresAsInfinitelyBad() {
    let degenerate = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 100, y: 100)],
      labelPosition: CGPoint(x: 100, y: 100)
    )
    let endpoint = PolicyCanvasEscapeCandidate(
      side: .trailing,
      actual: CGPoint(x: 100, y: 100),
      exit: CGPoint(x: 100, y: 100),
      routed: CGPoint(x: 100, y: 100)
    )
    let context = PolicyCanvasRouteContext(
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil
    )

    let score = policyCanvasDisplayedRouteScore(
      degenerate,
      source: endpoint,
      target: endpoint,
      context: context
    )

    #expect(score == .greatestFiniteMagnitude)
  }

  @Test("two-point real route scores finite")
  func twoPointRealRouteScoresFinite() {
    let real = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: CGPoint(x: 50, y: 0)
    )
    let endpoint = PolicyCanvasEscapeCandidate(
      side: .trailing,
      actual: .zero,
      exit: .zero,
      routed: .zero
    )
    let context = PolicyCanvasRouteContext(
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil
    )

    let score = policyCanvasDisplayedRouteScore(
      real,
      source: endpoint,
      target: endpoint,
      context: context
    )

    #expect(score < .greatestFiniteMagnitude)
  }
}
