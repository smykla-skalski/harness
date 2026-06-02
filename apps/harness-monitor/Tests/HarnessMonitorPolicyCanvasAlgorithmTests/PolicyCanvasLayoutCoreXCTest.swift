import CoreGraphics
import XCTest

@testable import HarnessMonitorPolicyCanvasAlgorithms

final class PolicyCanvasLayoutCoreXCTest: XCTestCase {
  private let fixtures = PolicyCanvasAutomaticLayoutEngineTests()

  func testLayeredEngineReducesCrossings() {
    let graph = fixtures.crossingReductionGraph()
    let naiveMetrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: [
        "a": CGPoint(x: 72, y: 72),
        "b": CGPoint(x: 72, y: 332),
        "c": CGPoint(x: 532, y: 72),
        "d": CGPoint(x: 532, y: 332),
      ],
      groupRanks: [
        "a": 0,
        "b": 0,
        "c": 1,
        "d": 1,
      ],
      layoutGroupIDByNodeID: [
        "a": "a",
        "b": "b",
        "c": "c",
        "d": "d",
      ]
    )

    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph)
    XCTAssertNotNil(result)
    XCTAssertEqual(naiveMetrics.edgeCrossingCount, 1)
    XCTAssertEqual(result?.metrics.edgeCrossingCount, 0)
    XCTAssertEqual(result?.metrics.flowDirectionViolationCount, 0)
    XCTAssertTrue((result?.metrics.readabilityScore ?? 0) > naiveMetrics.readabilityScore)
  }

  func testMetricsCaptureBackwardFlowViolations() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(id: "left", groupID: nil, originalIndex: 0, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(id: "right", groupID: nil, originalIndex: 1, currentPosition: .zero, anchor: nil),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "back-edge", sourceNodeID: "left", targetNodeID: "right"),
      ],
      groups: []
    )

    let metrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: [
        "left": CGPoint(x: 420, y: 72),
        "right": CGPoint(x: 72, y: 72),
      ],
      groupRanks: [
        "left": 0,
        "right": 1,
      ],
      layoutGroupIDByNodeID: [
        "left": "left",
        "right": "right",
      ]
    )

    XCTAssertEqual(metrics.flowDirectionViolationCount, 1)
    XCTAssertLessThan(metrics.readabilityScore, 1_000)
  }

  func testFeedbackEdgesAreReversedBeforeLayeredRanking() {
    let edges = [
      PolicyCanvasLayoutEdge(id: "a-b", sourceNodeID: "a", targetNodeID: "b"),
      PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      PolicyCanvasLayoutEdge(id: "c-a", sourceNodeID: "c", targetNodeID: "a"),
    ]

    let acyclicEdges = policyCanvasAcyclicEdges(
      ids: ["a", "b", "c"],
      originalOrder: ["a": 0, "b": 1, "c": 2],
      edges: edges
    )

    XCTAssertTrue(
      acyclicEdges.contains { edge in
        edge.id == "c-a" && edge.sourceNodeID == "a" && edge.targetNodeID == "c"
      }
    )

    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: fixtures.cycleGraph())
    XCTAssertNotNil(result)
    XCTAssertGreaterThanOrEqual(Set(result?.nodePositions.values.map(\.x) ?? []).count, 2)
  }

  func testDecisionTerminalCombIsInvariantUnderEdgeReversal() {
    let nodePositions: [String: CGPoint] = [
      "left-a": CGPoint(x: 120, y: 500),
      "left-b": CGPoint(x: 320, y: 500),
      "left-c": CGPoint(x: 520, y: 500),
      "right-a": CGPoint(x: 920, y: 500),
      "right-b": CGPoint(x: 1120, y: 500),
      "right-c": CGPoint(x: 1320, y: 500),
      "collector-left": CGPoint(x: 0, y: 0),
      "collector-right": CGPoint(x: 0, y: 0),
    ]
    let edges = [
      PolicyCanvasLayoutEdge(id: "left-1", sourceNodeID: "left-a", targetNodeID: "collector-left"),
      PolicyCanvasLayoutEdge(id: "left-2", sourceNodeID: "left-b", targetNodeID: "collector-left"),
      PolicyCanvasLayoutEdge(id: "left-3", sourceNodeID: "left-c", targetNodeID: "collector-left"),
      PolicyCanvasLayoutEdge(id: "right-1", sourceNodeID: "right-a", targetNodeID: "collector-right"),
      PolicyCanvasLayoutEdge(id: "right-2", sourceNodeID: "right-b", targetNodeID: "collector-right"),
      PolicyCanvasLayoutEdge(id: "right-3", sourceNodeID: "right-c", targetNodeID: "collector-right"),
    ]

    let forward = policyCanvasArrangedDecisionTerminals(
      nodePositions: nodePositions,
      edges: edges
    )
    let reversed = policyCanvasArrangedDecisionTerminals(
      nodePositions: nodePositions,
      edges: Array(edges.reversed())
    )

    XCTAssertEqual(forward["collector-left"], reversed["collector-left"])
    XCTAssertEqual(forward["collector-right"], reversed["collector-right"])
  }
}
