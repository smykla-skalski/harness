import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

/// The port-detachment measure flags a wire whose drawn endpoint lands away from
/// the rendered port dot. It compares each routed terminal against the marker
/// center the canvas actually draws (from the supplied `PolicyCanvasPortMarkerLayout`),
/// so it catches the routing-vs-marker disagreement the eye reads as a floating
/// wire end.
struct PolicyCanvasPortDetachmentTests {
  private let sourceOut = PolicyCanvasPortEndpoint(nodeID: "a", portID: "out", kind: .output)
  private let targetIn = PolicyCanvasPortEndpoint(nodeID: "b", portID: "in", kind: .input)

  private func nodes() -> [String: PolicyCanvasNode] {
    var source = PolicyCanvasNode(id: "a", title: "A", kind: .actionStep, position: CGPoint(x: 0, y: 0))
    source.inputPorts = []
    source.outputPorts = [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    var target = PolicyCanvasNode(
      id: "b", title: "B", kind: .actionStep, position: CGPoint(x: 400, y: 0)
    )
    target.inputPorts = [PolicyCanvasPort(id: "in", title: "in", kind: .input)]
    target.outputPorts = []
    return ["a": source, "b": target]
  }

  private func layout() -> PolicyCanvasPortMarkerLayout {
    let sourceKey = PolicyCanvasRouteTerminalKey(edgeID: "e", role: .source)
    let targetKey = PolicyCanvasRouteTerminalKey(edgeID: "e", role: .target)
    return PolicyCanvasPortMarkerLayout(
      terminalsByKey: [
        sourceKey: PolicyCanvasPortTerminal(side: .trailing, axisOffset: 0),
        targetKey: PolicyCanvasPortTerminal(side: .leading, axisOffset: 0),
      ],
      endpointsByKey: [sourceKey: sourceOut, targetKey: targetIn]
    )
  }

  private func report(targetOffset: CGSize, layout: PolicyCanvasPortMarkerLayout?)
    -> PolicyCanvasGraphQualityReport
  {
    let nodeIndex = nodes()
    let sourceCenter = policyCanvasPortMarkerCenter(
      endpoint: sourceOut,
      terminal: PolicyCanvasPortTerminal(side: .trailing, axisOffset: 0),
      nodesByID: nodeIndex
    )!
    let targetCenter = policyCanvasPortMarkerCenter(
      endpoint: targetIn,
      terminal: PolicyCanvasPortTerminal(side: .leading, axisOffset: 0),
      nodesByID: nodeIndex
    )!
    let wireEnd = CGPoint(x: targetCenter.x + targetOffset.width, y: targetCenter.y + targetOffset.height)
    let edge = PolicyCanvasEdge(id: "e", source: sourceOut, target: targetIn, label: "")
    let route = PolicyCanvasEdgeRoute(points: [sourceCenter, wireEnd], labelPosition: .zero)
    return policyCanvasMeasureGraphQuality(
      nodes: Array(nodeIndex.values),
      groups: [],
      edges: [edge],
      routes: ["e": route],
      portMarkerLayout: layout
    )
  }

  @Test func wireEndingAtItsDotIsNotDetached() {
    #expect(report(targetOffset: .zero, layout: layout()).count(for: .portDetached) == 0)
  }

  @Test func wireEndingWithinADotWidthIsNotDetached() {
    // 10px gap: under a full port diameter, the wire still meets the dot.
    #expect(report(targetOffset: CGSize(width: -10, height: 0), layout: layout()).count(for: .portDetached) == 0)
  }

  @Test func wireEndingFarFromItsDotIsDetached() {
    let result = report(targetOffset: CGSize(width: -100, height: 0), layout: layout())
    #expect(result.count(for: .portDetached) == 1)
    let violation = try! #require(result.portSpacing.first { $0.kind == .detached })
    #expect(violation.edgeIDs == ["e"])
    #expect(abs(violation.gap - 100) < 0.001)
    // `point` is the dot, `otherPoint` is where the wire actually ends.
    #expect(violation.otherPoint != nil)
  }

  @Test func nilLayoutSkipsDetachment() {
    #expect(report(targetOffset: CGSize(width: -100, height: 0), layout: nil).count(for: .portDetached) == 0)
  }
}
