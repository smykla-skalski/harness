import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Legend glyph that mirrors the canvas overlay marker for one graph-quality
/// category, so each metrics-panel row decodes the exact mark a developer sees
/// on the canvas. Color follows the category severity, matching the overlay
/// (error red, warning amber).
struct PolicyCanvasQualityMarkerSwatch: View {
  let category: PolicyCanvasQualityCategory

  var body: some View {
    Canvas { context, size in
      let tint = Self.tint(for: category)
      let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
      switch category {
      case .portOverlaps, .portTooClose, .portDetached:
        ring(&context, rect, tint)
      case .corridorReuse, .corridorParallel:
        thickLine(&context, rect, tint)
      case .crossings:
        ring(&context, rect, tint)
      case .crossingsIndependent:
        dot(&context, rect, tint)
      case .bodyHits:
        roundedOutline(&context, rect, tint)
      case .longEdges:
        dashedRect(&context, rect, tint)
      case .detours:
        detourGlyph(&context, rect, tint)
      case .nodeDistance:
        dimensionGlyph(&context, rect, tint)
      case .wrongTurns:
        wrongTurnGlyph(&context, rect, tint)
      case .crossedPorts:
        crossedPortsGlyph(&context, rect, tint)
      case .labelOverlaps, .labelOnBody, .labelAdrift:
        thinOutline(&context, rect, tint)
      case .nodeOverlaps:
        filledRect(&context, rect, tint)
      }
    }
    .frame(width: 18, height: 12)
    .accessibilityHidden(true)
  }

  static func tint(for category: PolicyCanvasQualityCategory) -> Color {
    switch category.severity {
    case .error: PolicyCanvasVisualStyle.blockedTint
    case .warning: PolicyCanvasVisualStyle.warningTint
    }
  }

  private func ring(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    context.stroke(Path(ellipseIn: centeredSquare(rect, side: 8)), with: .color(tint), lineWidth: 1.5)
  }

  private func dot(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    context.fill(Path(ellipseIn: centeredSquare(rect, side: 6)), with: .color(tint))
  }

  private func thickLine(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    context.stroke(
      path,
      with: .color(tint.opacity(0.55)),
      style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
    )
  }

  private func dashedRect(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    context.stroke(
      Path(rect),
      with: .color(tint.opacity(0.8)),
      style: StrokeStyle(lineWidth: 1, dash: [3, 2])
    )
  }

  private func roundedOutline(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    context.stroke(
      Path(roundedRect: rect, cornerSize: CGSize(width: 3, height: 3)),
      with: .color(tint),
      lineWidth: 1.5
    )
  }

  private func thinOutline(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    context.stroke(Path(rect.insetBy(dx: 0, dy: 1)), with: .color(tint.opacity(0.85)), lineWidth: 1)
  }

  private func filledRect(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    let inner = rect.insetBy(dx: 1, dy: 1)
    context.fill(Path(inner), with: .color(tint.opacity(0.3)))
    context.stroke(Path(inner), with: .color(tint), lineWidth: 1.2)
  }

  private func detourGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.midX - 2, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.midX - 2, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.midX + 2, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.midX + 2, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    context.stroke(
      path,
      with: .color(tint.opacity(0.55)),
      style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
    )
  }

  private func wrongTurnGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    // A path that runs out, drops, and hooks back with an arrowhead - a backtrack.
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 1))
    path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 1))
    path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1))
    path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 1))
    context.stroke(
      path,
      with: .color(tint.opacity(0.75)),
      style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    )
    var head = Path()
    head.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
    head.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 3.5))
    head.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY + 1.5))
    head.closeSubpath()
    context.fill(head, with: .color(tint))
  }

  private func crossedPortsGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    // Two dots joined by an X: a crossed pair of ports.
    let inner = rect.insetBy(dx: 4, dy: 1)
    var crosses = Path()
    crosses.move(to: CGPoint(x: inner.minX, y: inner.minY))
    crosses.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
    crosses.move(to: CGPoint(x: inner.minX, y: inner.maxY))
    crosses.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
    context.stroke(crosses, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
  }

  private func dimensionGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    for x in [rect.minX, rect.maxX] {
      path.move(to: CGPoint(x: x, y: rect.midY - 3))
      path.addLine(to: CGPoint(x: x, y: rect.midY + 3))
    }
    context.stroke(path, with: .color(tint), lineWidth: 1.2)
  }

  private func centeredSquare(_ rect: CGRect, side: CGFloat) -> CGRect {
    CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
  }
}
