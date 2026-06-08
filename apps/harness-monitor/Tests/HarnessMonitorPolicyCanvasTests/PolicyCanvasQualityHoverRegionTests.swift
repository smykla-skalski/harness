import CoreGraphics
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// The on-canvas hover layer turns each overlay mark into a tooltip region. These
/// guard that the hit regions match the report: one region per non-empty
/// category, returned in category-declaration order, with each region's fat path
/// actually covering its violation geometry so a pointer on the mark resolves the
/// tooltip while empty canvas stays click-through.
@Suite
struct PolicyCanvasQualityHoverRegionTests {
  @Test("an empty report produces no hover regions")
  func emptyReportHasNoRegions() {
    #expect(policyCanvasQualityHoverRegions(report: .empty).isEmpty)
  }

  @Test("each non-empty category contributes exactly one region")
  func oneRegionPerNonEmptyCategory() {
    var report = PolicyCanvasGraphQualityReport.empty
    report.portSpacing = [detachedPort(at: CGPoint(x: 200, y: 150))]
    report.wrongTurns = [
      PolicyCanvasWrongTurnViolation(
        edgeID: "e", point: CGPoint(x: 100, y: 100),
        returnPoint: CGPoint(x: 100, y: 160), depth: 60)
    ]
    report.nodeOverlaps = [
      PolicyCanvasNodeOverlapViolation(
        nodeA: "a", nodeB: "b",
        intersection: CGRect(x: 10, y: 10, width: 40, height: 30))
    ]
    let categories = policyCanvasQualityHoverRegions(report: report).map(\.category)
    #expect(Set(categories) == [.portDetached, .wrongTurns, .nodeOverlaps])
    #expect(categories.count == 3)
  }

  @Test("regions are returned in category-declaration order")
  func regionsFollowCategoryOrder() {
    var report = PolicyCanvasGraphQualityReport.empty
    // Seeded out of order: the last category before the first.
    report.nodeOverlaps = [
      PolicyCanvasNodeOverlapViolation(
        nodeA: "a", nodeB: "b",
        intersection: CGRect(x: 0, y: 0, width: 20, height: 20))
    ]
    report.portSpacing = [
      PolicyCanvasPortSpacingViolation(
        kind: .overlap, nodeID: "n", side: .leading,
        point: CGPoint(x: 5, y: 5), otherPoint: nil, gap: 1, edgeIDs: ["e"])
    ]
    let categories = policyCanvasQualityHoverRegions(report: report).map(\.category)
    #expect(categories == [.portOverlaps, .nodeOverlaps])
  }

  @Test("a port-dot region covers the marker point and excludes far canvas")
  func portDotRegionCoversItsPoint() throws {
    var report = PolicyCanvasGraphQualityReport.empty
    let point = CGPoint(x: 200, y: 150)
    report.portSpacing = [detachedPort(at: point)]
    let region = try #require(policyCanvasQualityHoverRegions(report: report).first)
    #expect(region.path.contains(point))
    #expect(region.path.contains(CGPoint(x: point.x + 6, y: point.y)))
    #expect(!region.path.contains(CGPoint(x: point.x, y: point.y + 200)))
  }

  @Test("a wrong-turn region covers the spur between its endpoints")
  func wrongTurnRegionCoversTheSpur() throws {
    var report = PolicyCanvasGraphQualityReport.empty
    let turn = CGPoint(x: 100, y: 100)
    let back = CGPoint(x: 100, y: 160)
    report.wrongTurns = [
      PolicyCanvasWrongTurnViolation(
        edgeID: "e", point: turn, returnPoint: back, depth: 60)
    ]
    let region = try #require(policyCanvasQualityHoverRegions(report: report).first)
    #expect(region.path.contains(CGPoint(x: 100, y: 130)))
    #expect(region.path.contains(back))
    #expect(!region.path.contains(CGPoint(x: 300, y: 130)))
  }

  private func detachedPort(at point: CGPoint) -> PolicyCanvasPortSpacingViolation {
    PolicyCanvasPortSpacingViolation(
      kind: .detached, nodeID: "n", side: .leading,
      point: point, otherPoint: nil, gap: 0, edgeIDs: ["e"])
  }
}
