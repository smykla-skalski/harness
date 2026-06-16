import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One hoverable mark: the fat hit path for a single violation, tagged with its
/// category and carrying its bounding box for a cheap first-pass hit test. Every
/// violation is its own mark (no per-category merge), so marks that overlap at a
/// point stay distinct and can all light up at once.
struct PolicyCanvasQualityHoverMark: Identifiable {
  let id: Int
  let category: PolicyCanvasQualityCategory
  let path: Path
  let bounds: CGRect
}

/// Highlight + tooltip layer for the quality overlay. A pure renderer: the AppKit
/// document view tracks the pointer (`PolicyCanvasNativeDocumentView` mouse
/// tracking) and publishes the marks under it to `viewModel.hoveredQualityMarks`;
/// this layer fills and strokes each of those marks in the canvas accent and
/// floats a tooltip naming every defect covered. It never hit-tests
/// (`allowsHitTesting(false)`). In this hosted canvas, SwiftUI pointer tracking on
/// a content-space overlay is unreliable, but rendering from observed state is
/// not - so interaction lives in AppKit and only drawing lives here. Lab-only.
struct PolicyCanvasQualityHoverLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    let active = viewModel.hoveredQualityMarks
    if !active.isEmpty {
      ZStack(alignment: .topLeading) {
        Canvas { context, _ in
          let accent = PolicyCanvasVisualStyle.activeTint
          for mark in active {
            context.fill(mark.path, with: .color(accent.opacity(0.12)))
            context.stroke(
              mark.path,
              with: .color(accent.opacity(0.5)),
              style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
          }
        }
        if let anchor = tooltipAnchor(for: active) {
          PolicyCanvasQualityHoverTooltip(titles: tooltipTitles(for: active))
            .position(anchor)
        }
      }
      .allowsHitTesting(false)
    }
  }

  /// Distinct category titles under the pointer, in first-seen order, so a stack
  /// of overlapping marks names every defect it covers - not just one.
  private func tooltipTitles(for active: [PolicyCanvasQualityHoverMark]) -> [String] {
    var titles: [String] = []
    var seen: Set<PolicyCanvasQualityCategory> = []
    for mark in active where seen.insert(mark.category).inserted {
      titles.append(mark.category.label)
    }
    return titles
  }

  /// Where to float the tooltip: centered just above the combined bounds of the
  /// hovered marks, or just below when that would clip past the top edge.
  private func tooltipAnchor(for active: [PolicyCanvasQualityHoverMark]) -> CGPoint? {
    guard var union = active.first?.bounds else {
      return nil
    }
    for mark in active.dropFirst() {
      union = union.union(mark.bounds)
    }
    let above = union.minY - 14
    return CGPoint(x: union.midX, y: above < 12 ? union.maxY + 14 : above)
  }
}

/// Small floating label that names every defect under the pointer, one title per
/// line. Rendered inside the content-space hover layer and positioned by it.
private struct PolicyCanvasQualityHoverTooltip: View {
  let titles: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(titles, id: \.self) { title in
        Text(title)
          .font(.caption2.weight(.medium))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(.regularMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(PolicyCanvasVisualStyle.activeTint.opacity(0.65), lineWidth: 1)
    )
    .fixedSize()
    .allowsHitTesting(false)
  }
}

/// The marks under a point: every mark whose bounding box and fat path both
/// contain it. Several stacked marks all pass, so overlapping defects resolve and
/// light up together. The bounding-box test rejects the vast majority cheaply, so
/// `Path.contains` runs only on the few survivors. Shared by the AppKit hover
/// tracking and the region tests so both measure the exact same hit.
func policyCanvasQualityHoverMarks(
  in marks: [PolicyCanvasQualityHoverMark],
  under point: CGPoint
) -> [PolicyCanvasQualityHoverMark] {
  marks.filter { $0.bounds.contains(point) && $0.path.contains(point) }
}

/// Build one fat, fillable mark per violation from the report geometry, mirroring
/// the overlay marks with generous slop so a pointer near a thin mark still
/// resolves it. Returned in report order; each mark carries its bounding box.
func policyCanvasQualityHoverMarks(
  report: PolicyCanvasGraphQualityReport
) -> [PolicyCanvasQualityHoverMark] {
  var marks: [PolicyCanvasQualityHoverMark] = []
  func add(_ category: PolicyCanvasQualityCategory, _ path: Path) {
    guard !path.isEmpty else {
      return
    }
    marks.append(
      PolicyCanvasQualityHoverMark(
        id: marks.count,
        category: category,
        path: path,
        bounds: path.boundingRect
      )
    )
  }
  for violation in report.portSpacing {
    let category: PolicyCanvasQualityCategory =
      switch violation.kind {
      case .overlap: .portOverlaps
      case .tooClose: .portTooClose
      case .detached: .portDetached
      }
    add(category, Path(ellipseIn: policyCanvasHoverDot(violation.point, radius: 10)))
  }
  for violation in report.crossings {
    add(
      violation.sharesEndpointNode ? .crossings : .crossingsIndependent,
      Path(ellipseIn: policyCanvasHoverDot(violation.point, radius: 9))
    )
  }
  for violation in report.corridors {
    add(
      violation.kind == .collinear ? .corridorReuse : .corridorParallel,
      policyCanvasHoverLine(violation.overlapStart, violation.overlapEnd, width: 16)
    )
  }
  for violation in report.bodyHits {
    add(.bodyHits, policyCanvasHoverRect(violation.frame))
  }
  for violation in report.longEdges {
    // A long edge marks its bounding box, but the wire only runs along the box
    // border - the interior is empty. Hover the border band, not the whole body,
    // so the highlight traces the frame the overlay draws and the empty middle
    // stays pass-through.
    add(.longEdges, policyCanvasHoverPerimeterBand(violation.bounds, band: 14))
  }
  for violation in report.detours {
    add(.detours, policyCanvasHoverPolyline(violation.points, width: 16))
  }
  for violation in report.nodeDistance {
    add(.nodeDistance, policyCanvasHoverLine(violation.gapStart, violation.gapEnd, width: 14))
  }
  for violation in report.wrongTurns {
    // Round-capped fat line only: the width-16 cap (radius 8) already covers the
    // size-6 arrowhead at the return point. A separate end dot is avoided on
    // purpose - an `addEllipse` winds opposite the `strokedPath` line, so under
    // the nonzero fill `contains` uses, their overlap would read as a hole at the
    // spur tip.
    add(.wrongTurns, policyCanvasHoverLine(violation.point, violation.returnPoint, width: 16))
  }
  for violation in report.crossedPorts {
    add(.crossedPorts, policyCanvasHoverLine(violation.pointA, violation.pointB, width: 18))
  }
  for violation in report.labels {
    let category: PolicyCanvasQualityCategory =
      switch violation.kind {
      case .overlap: .labelOverlaps
      case .onBody: .labelOnBody
      case .farFromEdge: .labelAdrift
      case .crossesEdge: .labelOnEdge
      case .nearTurn: .labelNearTurn
      }
    add(category, Path(violation.frame.insetBy(dx: -4, dy: -4)))
  }
  for violation in report.nodeOverlaps {
    add(.nodeOverlaps, Path(violation.intersection.insetBy(dx: -4, dy: -4)))
  }
  return marks
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

/// A solid, slightly-outset rounded rect over a frame mark (body hit, long-edge
/// bounds). Solid - not a stroked-rect ring - so filling it never bowties into
/// corner triangles when the frame is thinner than a ring stroke would be, and
/// the whole frame is hoverable. The outset also gives a thin frame enough
/// thickness to land a pointer on.
private func policyCanvasHoverRect(_ rect: CGRect) -> Path {
  Path(roundedRect: rect.insetBy(dx: -6, dy: -6), cornerRadius: 6)
}

/// A band that traces the rect perimeter rather than filling it - the hover region
/// for a frame mark (a long-edge bounding box) whose interior is empty space the
/// wire never enters. Built as an outer rectangle wound clockwise and an inner
/// rectangle wound counter-clockwise, so under nonzero winding (what both the
/// `fill` renderer and `Path.contains` use) the interior cancels to a hole and
/// only the band is inside - no even-odd, and no `strokedPath` corner bowtie. A
/// box too thin for an inner hole stays a solid block, the right read for a thin
/// long edge.
private func policyCanvasHoverPerimeterBand(_ rect: CGRect, band: CGFloat) -> Path {
  let outer = rect.insetBy(dx: -band / 2, dy: -band / 2)
  let inner = rect.insetBy(dx: band / 2, dy: band / 2)
  var path = Path()
  path.move(to: CGPoint(x: outer.minX, y: outer.minY))
  path.addLine(to: CGPoint(x: outer.maxX, y: outer.minY))
  path.addLine(to: CGPoint(x: outer.maxX, y: outer.maxY))
  path.addLine(to: CGPoint(x: outer.minX, y: outer.maxY))
  path.closeSubpath()
  guard inner.width > 0, inner.height > 0 else {
    return path
  }
  path.move(to: CGPoint(x: inner.minX, y: inner.minY))
  path.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
  path.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
  path.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
  path.closeSubpath()
  return path
}
