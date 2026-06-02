import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas port anchor")
@MainActor
struct PolicyCanvasAnchorTests {
  @Test("anchor is nil for an unknown node id")
  func anchorIsNilForUnknownNode() {
    let viewModel = PolicyCanvasViewModel.sample()
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: "no-such-node",
      portID: "output-event",
      kind: .output
    )

    #expect(viewModel.portAnchor(for: endpoint) == nil)
  }

  @Test("anchor is nil for a known node but unknown port id")
  func anchorIsNilForUnknownPort() {
    let viewModel = PolicyCanvasViewModel.sample()
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: "policy-source",
      portID: "no-such-port",
      kind: .output
    )

    #expect(viewModel.portAnchor(for: endpoint) == nil)
  }

  @Test("anchor is nil when the port id exists but on the wrong side")
  func anchorIsNilForWrongSidePort() {
    let viewModel = PolicyCanvasViewModel.sample()

    // policy-source has output "output-event" but no input port with that id.
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: "policy-source",
      portID: "output-event",
      kind: .input
    )

    #expect(viewModel.portAnchor(for: endpoint) == nil)
  }

  @Test("input port anchor sits on the node's leading edge")
  func inputPortAnchorMatchesLayoutMath() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("risk-score") else {
      Issue.record("expected risk-score node")
      return
    }
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: node.id,
      portID: "input-in",
      kind: .input
    )

    let anchor = viewModel.portAnchor(for: endpoint)

    let expectedY =
      node.position.y
      + PolicyCanvasLayout.portY(
        index: 0,
        count: node.inputPorts.count
      )
    #expect(anchor?.x == node.position.x)
    #expect(anchor?.y == expectedY)
  }

  @Test("output port anchor sits on the node's trailing edge")
  func outputPortAnchorMatchesLayoutMath() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("risk-score") else {
      Issue.record("expected risk-score node")
      return
    }
    let outputCount = node.outputPorts.count
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: node.id,
      portID: "output-fail",
      kind: .output
    )
    guard let portIndex = node.outputPorts.firstIndex(where: { $0.id == "output-fail" }) else {
      Issue.record("expected output-fail port on risk-score")
      return
    }

    let anchor = viewModel.portAnchor(for: endpoint)

    let expectedX = node.position.x + PolicyCanvasLayout.nodeSize.width
    let expectedY =
      node.position.y
      + PolicyCanvasLayout.portY(
        index: portIndex,
        count: outputCount
      )
    #expect(anchor?.x == expectedX)
    #expect(anchor?.y == expectedY)
  }

  @Test("top and bottom anchors use horizontal port spacing")
  func verticalPortAnchorsMatchLayoutMath() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("risk-score") else {
      Issue.record("expected risk-score node")
      return
    }

    let topAnchor = viewModel.portAnchor(
      for: PolicyCanvasPortEndpoint(
        nodeID: node.id,
        portID: "input-in",
        kind: .input,
        side: .top
      )
    )
    let bottomAnchor = viewModel.portAnchor(
      for: PolicyCanvasPortEndpoint(
        nodeID: node.id,
        portID: "output-pass",
        kind: .output,
        side: .bottom
      )
    )

    #expect(topAnchor?.x == node.position.x + PolicyCanvasLayout.portX(index: 0, count: 1))
    #expect(topAnchor?.y == node.position.y)
    #expect(bottomAnchor?.x == node.position.x + PolicyCanvasLayout.portX(index: 0, count: 3))
    #expect(bottomAnchor?.y == node.position.y + PolicyCanvasLayout.nodeSize.height)
  }
}
