import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas edge animation - flow direction")
struct PolicyCanvasEdgeAnimationTests {
  @Test("isAnimated defaults to false on PolicyCanvasEdge")
  func defaultIsStatic() {
    let edge = PolicyCanvasEdge(
      id: "e",
      source: PolicyCanvasPortEndpoint(nodeID: "a", portID: "p", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "b", portID: "p", kind: .input),
      label: ""
    )
    #expect(edge.isAnimated == false)
  }

  @Test("isAnimated round-trips through the initializer")
  func roundTripsThroughInit() {
    let edge = PolicyCanvasEdge(
      id: "e",
      source: PolicyCanvasPortEndpoint(nodeID: "a", portID: "p", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "b", portID: "p", kind: .input),
      label: "",
      isAnimated: true
    )
    #expect(edge.isAnimated == true)
  }

  @Test("Dash phase advances monotonically with time")
  func dashPhaseAdvances() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let later = Date(timeIntervalSinceReferenceDate: 1_000.5)
    let phaseNow = PolicyCanvasEdgeAnimation.dashPhase(at: now)
    let phaseLater = PolicyCanvasEdgeAnimation.dashPhase(at: later)
    #expect(phaseNow != phaseLater)
  }

  @Test("Dash phase stays within the dash+gap cycle")
  func dashPhaseStaysInCycle() {
    let cycle = PolicyCanvasEdgeAnimation.dashPattern.reduce(0, +)
    for offset in stride(from: 0.0, to: 10.0, by: 0.07) {
      let date = Date(timeIntervalSinceReferenceDate: offset)
      let phase = PolicyCanvasEdgeAnimation.dashPhase(at: date)
      #expect(phase <= 0)
      #expect(phase > -cycle - 0.0001)
    }
  }
}
