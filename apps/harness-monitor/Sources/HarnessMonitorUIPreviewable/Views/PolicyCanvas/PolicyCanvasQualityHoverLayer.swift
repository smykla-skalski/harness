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

/// Interactive layer over the quality overlay. Tracks the pointer in content
/// space, finds every mark under it - across categories, however many overlap -
/// emphasizes each with the canvas accent, and names them in a native tooltip.
/// Lab-only. The hit area is the union of the marks, so hovering or clicking
/// empty canvas passes straight through to the nodes and wires below; node drags
/// are captured a level lower at the AppKit `hitTest`.
struct PolicyCanvasQualityHoverLayer: View {
  let report: PolicyCanvasGraphQualityReport
  let viewModel: PolicyCanvasViewModel

  @State private var hoverPoint: CGPoint?

  var body: some View {
    // Built inline from the passed report so the hit area is never momentarily
    // empty (an empty `.contentShape` would silently kill hover). `report` only
    // changes on an off-main recompute, and the body otherwise re-runs only when
    // `hoverPoint` moves, so this rebuild is the per-hover cost.
    let marks = policyCanvasQualityHoverMarks(report: report)
    let active = marks.filter(isUnderPointer)
    let hitArea = marks.reduce(into: Path()) { $0.addPath($1.path) }
    ZStack {
      Canvas { context, _ in
        let accent = PolicyCanvasVisualStyle.activeTint
        for mark in active {
          context.fill(mark.path, with: .color(accent.opacity(0.28)))
          context.stroke(
            mark.path,
            with: .color(accent.opacity(0.95)),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
          )
        }
      }
      .allowsHitTesting(false)
      Color.clear
        .contentShape(hitArea)
        .onContinuousHover { phase in
          switch phase {
          case .active(let location):
            hoverPoint = location
          case .ended:
            hoverPoint = nil
          }
        }
        .help(helpText(for: active))
    }
    .onChange(of: active.map(\.id)) {
      let categories = Set(active.map(\.category))
      if viewModel.hoveredQualityCategories != categories {
        viewModel.hoveredQualityCategories = categories
      }
    }
    .onDisappear {
      viewModel.hoveredQualityCategories = []
    }
  }

  /// Whether a mark's geometry sits under the pointer. The bounding-box test
  /// rejects the vast majority cheaply so `Path.contains` runs only on the few
  /// candidates left.
  private func isUnderPointer(_ mark: PolicyCanvasQualityHoverMark) -> Bool {
    guard let point = hoverPoint else {
      return false
    }
    return mark.bounds.contains(point) && mark.path.contains(point)
  }

  /// One block per distinct category under the pointer, first-seen order, so a
  /// stack of overlapping marks names every defect it covers - not just one.
  private func helpText(for active: [PolicyCanvasQualityHoverMark]) -> String {
    var ordered: [PolicyCanvasQualityCategory] = []
    for mark in active where !ordered.contains(mark.category) {
      ordered.append(mark.category)
    }
    return ordered.map { "\($0.label): \($0.detail)" }.joined(separator: "\n\n")
  }
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
    add(.bodyHits, policyCanvasHoverBand(violation.frame, width: 14))
  }
  for violation in report.longEdges {
    add(.longEdges, policyCanvasHoverBand(violation.bounds, width: 14))
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
  for violation in report.labels {
    let category: PolicyCanvasQualityCategory =
      switch violation.kind {
      case .overlap: .labelOverlaps
      case .onBody: .labelOnBody
      case .farFromEdge: .labelAdrift
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

private func policyCanvasHoverBand(_ rect: CGRect, width: CGFloat) -> Path {
  Path(rect).strokedPath(StrokeStyle(lineWidth: width))
}
