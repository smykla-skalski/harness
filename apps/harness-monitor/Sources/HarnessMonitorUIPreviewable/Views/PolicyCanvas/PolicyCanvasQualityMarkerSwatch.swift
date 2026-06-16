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
      case .portUneven:
        portUnevenGlyph(&context, rect, tint)
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
      case .labelOverlaps:
        labelOverlapsGlyph(&context, rect, tint)
      case .labelOnBody:
        labelOnBodyGlyph(&context, rect, tint)
      case .labelAdrift:
        labelAdriftGlyph(&context, rect, tint)
      case .labelOnEdge:
        labelOnEdgeGlyph(&context, rect, tint)
      case .labelNearTurn:
        labelNearTurnGlyph(&context, rect, tint)
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

  /// A solid ring on the left, a dashed arrow, and a hollow ghost ring on the
  /// right - a dot nudged toward the even slot it should occupy.
  private func portUnevenGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    let solid = CGRect(x: rect.minX, y: rect.midY - 3, width: 6, height: 6)
    let ghost = CGRect(x: rect.maxX - 6, y: rect.midY - 3, width: 6, height: 6)
    context.stroke(Path(ellipseIn: solid), with: .color(tint), lineWidth: 1.2)
    context.stroke(
      Path(ellipseIn: ghost),
      with: .color(tint.opacity(0.6)),
      style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])
    )
    var arrow = Path()
    arrow.move(to: CGPoint(x: solid.maxX, y: rect.midY))
    arrow.addLine(to: CGPoint(x: ghost.minX, y: rect.midY))
    context.stroke(
      arrow,
      with: .color(tint.opacity(0.7)),
      style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 1.5])
    )
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

  /// A small label-box rect centered in the swatch, the shared base every label
  /// glyph decorates so the family still reads as "a label" while each kind's
  /// decoration tells them apart.
  private func labelBox(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.midX - 6, y: rect.midY - 3.5, width: 12, height: 7)
  }

  private func labelOverlapsGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    let box = labelBox(rect)
    context.stroke(Path(box.offsetBy(dx: -1.5, dy: -1.5)), with: .color(tint), lineWidth: 1)
    context.stroke(Path(box.offsetBy(dx: 1.5, dy: 1.5)), with: .color(tint), lineWidth: 1)
  }

  private func labelOnBodyGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    let box = labelBox(rect)
    context.fill(Path(box), with: .color(tint.opacity(0.3)))
    context.stroke(Path(box), with: .color(tint), lineWidth: 1.2)
  }

  private func labelAdriftGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    context.stroke(
      Path(labelBox(rect)),
      with: .color(tint.opacity(0.85)),
      style: StrokeStyle(lineWidth: 1, dash: [2.5, 1.5])
    )
  }

  private func labelOnEdgeGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    let box = labelBox(rect)
    context.stroke(Path(box), with: .color(tint), lineWidth: 1)
    var strike = Path()
    strike.move(to: CGPoint(x: rect.minX, y: box.midY))
    strike.addLine(to: CGPoint(x: rect.maxX, y: box.midY))
    context.stroke(strike, with: .color(tint), lineWidth: 1.5)
  }

  private func labelNearTurnGlyph(_ context: inout GraphicsContext, _ rect: CGRect, _ tint: Color) {
    let box = labelBox(rect)
    context.stroke(Path(box), with: .color(tint), lineWidth: 1)
    let arm: CGFloat = 4
    var corner = Path()
    corner.move(to: CGPoint(x: box.maxX - arm, y: box.minY))
    corner.addLine(to: CGPoint(x: box.maxX, y: box.minY))
    corner.addLine(to: CGPoint(x: box.maxX, y: box.minY + arm))
    context.stroke(
      corner,
      with: .color(tint),
      style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    )
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
