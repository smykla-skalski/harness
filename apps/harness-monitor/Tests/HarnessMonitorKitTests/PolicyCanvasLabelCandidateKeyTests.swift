import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas label candidate dedup key")
struct PolicyCanvasLabelCandidateKeyTests {
  @Test("sub-quantum drift collapses to same key")
  func subQuantumDriftCollapses() {
    let a = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 100), quantum: 4)
    let b = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 101.5, y: 100), quantum: 4)
    #expect(a == b, "Sub-quantum drift should collapse to same key")
  }

  @Test("supra-quantum drift derives different key")
  func supraQuantumDriftDifferent() {
    let a = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 100), quantum: 4)
    let b = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 120, y: 100), quantum: 4)
    #expect(a != b)
  }

  @Test("differing y at same x derives different key")
  func differingYDerivesDifferentKey() {
    let a = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 100), quantum: 4)
    let b = PolicyCanvasLabelCandidateKey(point: CGPoint(x: 100, y: 120), quantum: 4)
    #expect(a != b)
  }
}
