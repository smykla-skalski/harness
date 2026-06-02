import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas label candidate dedup key")
struct PolicyCanvasLabelCandidateKeyTests {
  @Test("sub-quantum drift collapses to same key")
  func subQuantumDriftCollapses() {
    let baseKey = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 100), quantum: 4)
    let driftedKey = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 101.5, y: 100), quantum: 4)
    #expect(baseKey == driftedKey, "Sub-quantum drift should collapse to same key")
  }

  @Test("supra-quantum drift derives different key")
  func supraQuantumDriftDifferent() {
    let baseKey = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 100), quantum: 4)
    let driftedKey = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 120, y: 100), quantum: 4)
    #expect(baseKey != driftedKey)
  }

  @Test("differing y at same x derives different key")
  func differingYDerivesDifferentKey() {
    let baseKey = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 100), quantum: 4)
    let shiftedKey = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 120), quantum: 4)
    #expect(baseKey != shiftedKey)
  }
}
