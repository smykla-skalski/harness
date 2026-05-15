import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas edge kind - derivation and color")
struct PolicyCanvasEdgeKindTests {
  @Test("'always' maps to .flow")
  func alwaysIsFlow() {
    #expect(PolicyCanvasEdgeKind.derive(from: "always") == .flow)
  }

  @Test("Empty condition maps to .flow")
  func emptyIsFlow() {
    #expect(PolicyCanvasEdgeKind.derive(from: "") == .flow)
    #expect(PolicyCanvasEdgeKind.derive(from: "   ") == .flow)
  }

  @Test("Denied / error conditions map to .error")
  func deniedIsError() {
    #expect(PolicyCanvasEdgeKind.derive(from: "denied") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "DENY") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "request_failed") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "policy_reject") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "error_path") == .error)
  }

  @Test("Other non-empty conditions map to .control")
  func conditionalIsControl() {
    #expect(PolicyCanvasEdgeKind.derive(from: "approved") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "if x > 5") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "human_review") == .control)
  }

  @Test("Each kind exposes a distinct accent color")
  func distinctAccentColors() {
    let colors = PolicyCanvasEdgeKind.allCases.map { $0.accentColor.description }
    #expect(Set(colors).count == PolicyCanvasEdgeKind.allCases.count)
  }

  @Test("Edge init derives kind from condition when not explicit")
  func initDerivesKind() {
    let endpoint = PolicyCanvasPortEndpoint(nodeID: "n", portID: "p", kind: .output)
    let target = PolicyCanvasPortEndpoint(nodeID: "n2", portID: "p2", kind: .input)
    let flow = PolicyCanvasEdge(id: "e1", source: endpoint, target: target, label: "")
    #expect(flow.kind == .flow)
    let denied = PolicyCanvasEdge(
      id: "e2",
      source: endpoint,
      target: target,
      label: "",
      condition: "denied"
    )
    #expect(denied.kind == .error)
    let explicit = PolicyCanvasEdge(
      id: "e3",
      source: endpoint,
      target: target,
      label: "",
      condition: "always",
      kind: .control
    )
    #expect(explicit.kind == .control)
  }
}
