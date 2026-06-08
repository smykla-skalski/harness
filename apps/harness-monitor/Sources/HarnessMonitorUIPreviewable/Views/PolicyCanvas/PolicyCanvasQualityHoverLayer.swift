import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One hoverable region: the union of every hit shape for a single quality
/// category, paired with the category so the view can show its tooltip.
struct PolicyCanvasQualityHoverRegion: Identifiable {
  let category: PolicyCanvasQualityCategory
  let path: Path
  var id: PolicyCanvasQualityCategory { category }
}

/// Per-category hit regions over the quality overlay, each carrying a native
/// tooltip that names the defect under the pointer. Lab-only: it lets a developer
/// hover any mark on the canvas - a red port ring, a dashed long-edge box, a
/// backtrack arrow - and read what it is, without hunting the side-panel legend.
/// The hit region is limited to the marks themselves, so hovering or clicking
/// empty canvas passes straight through to the nodes below.
struct PolicyCanvasQualityHoverLayer: View {
  let report: PolicyCanvasGraphQualityReport

  var body: some View {
    ZStack {
      ForEach(policyCanvasQualityHoverRegions(report: report)) { region in
        Color.clear
          .contentShape(region.path)
          // `.onHover` installs the tracking area `.help` rides on, and the
          // category label keeps the now-visible element meaningful to
          // VoiceOver. `.help` attaches through the accessibility element, so
          // the layer must not be hidden from accessibility or the tooltip
          // never shows - matching how edge and port views expose their help.
          .onHover { _ in }
          .help(region.category.detail)
          .accessibilityLabel(Text(region.category.label))
      }
    }
  }
}

/// Build a fat, fillable hit path per category from the report geometry,
/// mirroring the overlay marks with generous slop so a pointer near a thin mark
/// still resolves it. Categories with no violations are dropped, so the layer
/// mounts only the tooltips that have something under them. Returned in category
/// declaration order for a stable mount.
func policyCanvasQualityHoverRegions(
  report: PolicyCanvasGraphQualityReport
) -> [PolicyCanvasQualityHoverRegion] {
  var paths: [PolicyCanvasQualityCategory: Path] = [:]
  func add(_ category: PolicyCanvasQualityCategory, _ build: (inout Path) -> Void) {
    build(&paths[category, default: Path()])
  }
  for violation in report.portSpacing {
    let category: PolicyCanvasQualityCategory =
      switch violation.kind {
      case .overlap: .portOverlaps
      case .tooClose: .portTooClose
      case .detached: .portDetached
      }
    add(category) { $0.addEllipse(in: policyCanvasHoverDot(violation.point, radius: 10)) }
  }
  for violation in report.crossings {
    add(violation.sharesEndpointNode ? .crossings : .crossingsIndependent) {
      $0.addEllipse(in: policyCanvasHoverDot(violation.point, radius: 9))
    }
  }
  for violation in report.corridors {
    add(violation.kind == .collinear ? .corridorReuse : .corridorParallel) {
      $0.addPath(policyCanvasHoverLine(violation.overlapStart, violation.overlapEnd, width: 16))
    }
  }
  for violation in report.bodyHits {
    add(.bodyHits) { $0.addPath(policyCanvasHoverBand(violation.frame, width: 14)) }
  }
  for violation in report.longEdges {
    add(.longEdges) { $0.addPath(policyCanvasHoverBand(violation.bounds, width: 14)) }
  }
  for violation in report.detours {
    add(.detours) { $0.addPath(policyCanvasHoverPolyline(violation.points, width: 16)) }
  }
  for violation in report.nodeDistance {
    add(.nodeDistance) {
      $0.addPath(policyCanvasHoverLine(violation.gapStart, violation.gapEnd, width: 14))
    }
  }
  for violation in report.wrongTurns {
    // One round-capped fat line: the width-16 cap (radius 8) already covers the
    // size-6 arrowhead at the return point. A separate end dot is avoided on
    // purpose - an `addEllipse` winds opposite the `strokedPath` line, so under
    // the nonzero fill `contentShape` uses, their overlap would cancel to a hole
    // exactly at the spur tip.
    add(.wrongTurns) {
      $0.addPath(policyCanvasHoverLine(violation.point, violation.returnPoint, width: 16))
    }
  }
  for violation in report.labels {
    let category: PolicyCanvasQualityCategory =
      switch violation.kind {
      case .overlap: .labelOverlaps
      case .onBody: .labelOnBody
      case .farFromEdge: .labelAdrift
      }
    add(category) { $0.addRect(violation.frame.insetBy(dx: -4, dy: -4)) }
  }
  for violation in report.nodeOverlaps {
    add(.nodeOverlaps) { $0.addRect(violation.intersection.insetBy(dx: -4, dy: -4)) }
  }
  return PolicyCanvasQualityCategory.allCases.compactMap { category in
    guard let path = paths[category], !path.isEmpty else {
      return nil
    }
    return PolicyCanvasQualityHoverRegion(category: category, path: path)
  }
}

private func policyCanvasHoverDot(_ point: CGPoint, radius: CGFloat) -> CGRect {
  CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
}

private func policyCanvasHoverLine(_ start: CGPoint, _ end: CGPoint, width: CGFloat) -> Path {
  var line = Path()
  line.move(to: start)
  line.addLine(to: end)
  return line.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
}

private func policyCanvasHoverPolyline(_ points: [CGPoint], width: CGFloat) -> Path {
  var line = Path()
  guard let first = points.first else {
    return line
  }
  line.move(to: first)
  for point in points.dropFirst() {
    line.addLine(to: point)
  }
  return line.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
}

private func policyCanvasHoverBand(_ rect: CGRect, width: CGFloat) -> Path {
  Path(rect).strokedPath(StrokeStyle(lineWidth: width))
}
