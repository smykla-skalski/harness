import CoreGraphics
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// The on-canvas hover layer turns each overlay mark into an individually
/// hoverable, highlightable hit path. These guard that every violation is its own
/// mark (so overlapping marks stay distinct), that a mark's fat path covers its
/// geometry, and - the point of the feature - that several marks stacked at one
/// spot all resolve at once.
@Suite
struct PolicyCanvasQualityHoverRegionTests {
  /// Mirror of the layer's per-pointer hit test, routed through the same shared
  /// filter the AppKit document view publishes from.
  private func marks(
    under point: CGPoint,
    in report: PolicyCanvasGraphQualityReport
  ) -> [PolicyCanvasQualityHoverMark] {
    policyCanvasQualityHoverMarks(
      in: policyCanvasQualityHoverMarks(report: report), under: point)
  }

  @Test("the shared filter returns every mark stacked at one point")
  func sharedFilterResolvesStack() {
    var report = PolicyCanvasGraphQualityReport.empty
    let shared = CGPoint(x: 100, y: 100)
    report.crossings = [
      PolicyCanvasCrossingViolation(
        edgeA: "a", edgeB: "b", point: shared, sharesEndpointNode: false)
    ]
    report.corridors = [
      PolicyCanvasCorridorViolation(
        kind: .collinear, isHorizontal: true, edgeA: "a", edgeB: "c",
        overlapStart: CGPoint(x: 50, y: 100), overlapEnd: CGPoint(x: 150, y: 100),
        separation: 0)
    ]
    let hit = policyCanvasQualityHoverMarks(
      in: policyCanvasQualityHoverMarks(report: report), under: shared)
    #expect(hit.count == 2)
    #expect(Set(hit.map(\.category)) == [.crossingsIndependent, .corridorReuse])
  }

  @Test("an empty report produces no marks")
  func emptyReportHasNoMarks() {
    #expect(policyCanvasQualityHoverMarks(report: .empty).isEmpty)
  }

  @Test("every violation is its own mark, even within one category")
  func eachViolationIsItsOwnMark() {
    var report = PolicyCanvasGraphQualityReport.empty
    report.portSpacing = [
      portOverlap(at: CGPoint(x: 100, y: 100)),
      portOverlap(at: CGPoint(x: 400, y: 100)),
    ]
    let marks = policyCanvasQualityHoverMarks(report: report)
    #expect(marks.count == 2)
    #expect(marks.allSatisfy { $0.category == .portOverlaps })
    #expect(Set(marks.map(\.id)).count == 2)
  }

  @Test("a mark covers its violation point and carries its category")
  func markCoversItsPoint() throws {
    var report = PolicyCanvasGraphQualityReport.empty
    let point = CGPoint(x: 200, y: 150)
    report.portSpacing = [
      PolicyCanvasPortSpacingViolation(
        kind: .detached, nodeID: "n", side: .leading,
        point: point, otherPoint: nil, gap: 0, edgeIDs: ["e"])
    ]
    let hit = marks(under: point, in: report)
    let mark = try #require(hit.first)
    #expect(hit.count == 1)
    #expect(mark.category == .portDetached)
    #expect(!mark.path.contains(CGPoint(x: point.x, y: point.y + 200)))
  }

  @Test("overlapping marks from different categories all resolve at the shared point")
  func overlappingMarksAllResolve() {
    var report = PolicyCanvasGraphQualityReport.empty
    let shared = CGPoint(x: 100, y: 100)
    report.crossings = [
      PolicyCanvasCrossingViolation(
        edgeA: "a", edgeB: "b", point: shared, sharesEndpointNode: false)
    ]
    report.corridors = [
      PolicyCanvasCorridorViolation(
        kind: .collinear, isHorizontal: true, edgeA: "a", edgeB: "c",
        overlapStart: CGPoint(x: 50, y: 100), overlapEnd: CGPoint(x: 150, y: 100),
        separation: 0)
    ]
    let hit = marks(under: shared, in: report)
    #expect(hit.count == 2)
    #expect(Set(hit.map(\.category)) == [.crossingsIndependent, .corridorReuse])
  }

  @Test("a wrong-turn mark covers the spur with no hole at the tip")
  func wrongTurnMarkCoversSpur() {
    var report = PolicyCanvasGraphQualityReport.empty
    report.wrongTurns = [
      PolicyCanvasWrongTurnViolation(
        edgeID: "e", point: CGPoint(x: 100, y: 100),
        returnPoint: CGPoint(x: 100, y: 160), depth: 60)
    ]
    #expect(marks(under: CGPoint(x: 100, y: 130), in: report).count == 1)
    #expect(marks(under: CGPoint(x: 100, y: 160), in: report).count == 1)
    #expect(marks(under: CGPoint(x: 300, y: 130), in: report).isEmpty)
  }

  private func portOverlap(at point: CGPoint) -> PolicyCanvasPortSpacingViolation {
    PolicyCanvasPortSpacingViolation(
      kind: .overlap, nodeID: "n", side: .leading,
      point: point, otherPoint: nil, gap: 1, edgeIDs: ["e"])
  }
}
