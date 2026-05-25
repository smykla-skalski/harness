import AppKit
import CoreText

@MainActor
extension DashboardReviewFileDiffGridContentView {
  func draw(
    row: DashboardReviewFileDiffRow,
    wrappedLayout: DashboardReviewFileDiffWrappedRowLayout,
    in rect: NSRect
  ) {
    fillBackground(for: row.kind, in: rect)
    if row.id == selectedRowID {
      DashboardReviewFileDiffMonokaiPalette.selection.withAlphaComponent(0.72).setFill()
      rect.fill()
    }
    switch viewMode {
    case .unified:
      drawUnified(row: row, wrappedLayout: wrappedLayout, in: rect)
    case .split:
      drawSplit(row: row, wrappedLayout: wrappedLayout, in: rect)
    }
  }

  private func drawUnified(
    row: DashboardReviewFileDiffRow,
    wrappedLayout: DashboardReviewFileDiffWrappedRowLayout,
    in rect: NSRect
  ) {
    if row.kind == .hunk || row.kind == .metadata || row.kind == .contextGap {
      drawControlText(wrappedLayout.displayLines, x: 12, rect: rect, kind: row.kind)
      return
    }
    let firstLineRect = visualLineRect(in: rect, lineIndex: 0)
    drawThreadBadge(for: row, x: 7, lineRect: firstLineRect)
    drawLineNumber(row.oldLine, rightX: 42, lineRect: firstLineRect)
    drawLineNumber(row.newLine, rightX: 84, lineRect: firstLineRect)
    drawPlainText(
      row.unifiedPrefix, x: 101, lineRect: firstLineRect, color: prefixColor(for: row.kind)
    )
    drawCodeLines(
      wrappedLayout.displayLines,
      x: 120,
      rect: rect
    )
  }

  private func drawSplit(
    row: DashboardReviewFileDiffRow,
    wrappedLayout: DashboardReviewFileDiffWrappedRowLayout,
    in rect: NSRect
  ) {
    if row.kind == .hunk || row.kind == .metadata || row.kind == .contextGap {
      drawControlText(wrappedLayout.displayLines, x: 12, rect: rect, kind: row.kind)
      return
    }
    let columnWidth = floor((bounds.width - 1) / 2)
    DashboardReviewFileDiffMonokaiPalette.separator.setFill()
    NSRect(x: columnWidth, y: rect.minY, width: 1, height: rect.height).fill()
    drawSplitSide(
      row: row,
      wrappedLayout: wrappedLayout,
      side: .old,
      x: 0,
      width: columnWidth,
      rect: rect
    )
    drawSplitSide(
      row: row,
      wrappedLayout: wrappedLayout,
      side: .new,
      x: columnWidth + 1,
      width: columnWidth,
      rect: rect
    )
  }

  private func drawSplitSide(
    row: DashboardReviewFileDiffRow,
    wrappedLayout: DashboardReviewFileDiffWrappedRowLayout,
    side: DashboardReviewFileDiffSide,
    x: CGFloat,
    width: CGFloat,
    rect: NSRect
  ) {
    guard isRow(row, visibleOn: side) else { return }
    let firstLineRect = visualLineRect(in: rect, lineIndex: 0)
    let line = side == .old ? row.oldLine : row.newLine
    let prefix = splitPrefix(for: row.kind, side: side)
    drawThreadBadge(for: row, side: side, x: x + 7, lineRect: firstLineRect)
    drawLineNumber(line, rightX: x + 42, lineRect: firstLineRect)
    drawPlainText(prefix, x: x + 58, lineRect: firstLineRect, color: prefixColor(for: row.kind))
    drawCodeLines(
      wrappedLayout.displayLines,
      x: x + 76,
      rect: rect
    )
  }

  private func codeLayout(for line: String) -> DashboardReviewFileDiffTextLineLayout {
    DashboardReviewFileDiffHighlightCache.layout(
      text: line,
      language: codeLanguage,
      font: font
    )
  }

  private func fillBackground(for kind: DashboardReviewFileDiffRow.Kind, in rect: NSRect) {
    let color =
      switch kind {
      case .addition:
        DashboardReviewFileDiffMonokaiPalette.additionBackground
      case .deletion:
        DashboardReviewFileDiffMonokaiPalette.deletionBackground
      case .hunk:
        DashboardReviewFileDiffMonokaiPalette.hunkBackground
      case .contextGap:
        DashboardReviewFileDiffMonokaiPalette.contextGapBackground
      case .metadata:
        DashboardReviewFileDiffMonokaiPalette.metadataBackground
      case .context:
        DashboardReviewFileDiffMonokaiPalette.contextBackground
      }
    color.setFill()
    rect.fill()
  }

  private func drawLineNumber(_ number: Int?, rightX: CGFloat, lineRect: NSRect) {
    guard let number else { return }
    guard
      let layout = DashboardReviewFileDiffPlainTextCache.layout(
        text: "\(number)",
        font: font,
        color: DashboardReviewFileDiffMonokaiPalette.comment
      )
    else { return }
    draw(layout: layout, x: rightX - layout.typographicWidth, lineRect: lineRect)
  }

  private func drawControlText(
    _ lines: [String],
    x: CGFloat,
    rect: NSRect,
    kind: DashboardReviewFileDiffRow.Kind
  ) {
    let color: NSColor =
      switch kind {
      case .contextGap:
        DashboardReviewFileDiffMonokaiPalette.comment
      case .metadata:
        DashboardReviewFileDiffMonokaiPalette.orange
      case .hunk:
        DashboardReviewFileDiffMonokaiPalette.blue
      case .addition, .context, .deletion:
        DashboardReviewFileDiffMonokaiPalette.foreground
      }
    for (index, line) in lines.enumerated() {
      let lineRect = visualLineRect(in: rect, lineIndex: index)
      drawPlainText(line, x: x, lineRect: lineRect, color: color)
    }
  }

  private func drawPlainText(_ text: String, x: CGFloat, lineRect: NSRect, color: NSColor) {
    guard
      let layout = DashboardReviewFileDiffPlainTextCache.layout(
        text: text,
        font: font,
        color: color
      )
    else { return }
    draw(layout: layout, x: x, lineRect: lineRect)
  }

  private func drawCodeLines(
    _ lines: [String],
    x: CGFloat,
    rect: NSRect
  ) {
    for (index, line) in lines.enumerated() {
      let lineRect = visualLineRect(in: rect, lineIndex: index)
      draw(layout: codeLayout(for: line), x: x, lineRect: lineRect)
    }
  }

  private func draw(
    layout: DashboardReviewFileDiffTextLineLayout,
    x: CGFloat,
    lineRect: NSRect
  ) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: 0, y: bounds.height)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = CGPoint(
      x: x,
      y: bounds.height - typographyMetrics.baselineY(for: layout.glyphBounds, in: lineRect)
    )
    CTLineDraw(layout.line, context)
    context.restoreGState()
  }

  private func visualLineRect(in rect: NSRect, lineIndex: Int) -> NSRect {
    NSRect(
      x: rect.minX, y: rect.minY + CGFloat(lineIndex) * rowHeight, width: rect.width,
      height: rowHeight
    )
  }

  private func splitPrefix(
    for kind: DashboardReviewFileDiffRow.Kind,
    side: DashboardReviewFileDiffSide
  ) -> String {
    switch (kind, side) {
    case (.addition, .new): "+"
    case (.deletion, .old): "-"
    case (.context, _): " "
    default: ""
    }
  }

  private func prefixColor(for kind: DashboardReviewFileDiffRow.Kind) -> NSColor {
    switch kind {
    case .addition: DashboardReviewFileDiffMonokaiPalette.green
    case .deletion: DashboardReviewFileDiffMonokaiPalette.red
    case .context: DashboardReviewFileDiffMonokaiPalette.comment
    case .contextGap: DashboardReviewFileDiffMonokaiPalette.comment
    case .hunk: DashboardReviewFileDiffMonokaiPalette.blue
    case .metadata: DashboardReviewFileDiffMonokaiPalette.orange
    }
  }

  private func isRow(
    _ row: DashboardReviewFileDiffRow,
    visibleOn side: DashboardReviewFileDiffSide
  ) -> Bool {
    switch (row.kind, side) {
    case (.addition, .new), (.deletion, .old), (.context, _):
      true
    default:
      false
    }
  }

  private func drawThreadBadge(
    for row: DashboardReviewFileDiffRow,
    side: DashboardReviewFileDiffSide? = nil,
    x: CGFloat,
    lineRect: NSRect
  ) {
    let anchors = threads(for: row, side: side)
    guard !anchors.isEmpty else { return }
    let title = anchors.count == 1 ? anchors[0].badgeTitle : "\(anchors.count)"
    let rect = typographyMetrics.badgeRect(in: lineRect, x: x)
    DashboardReviewFileDiffMonokaiPalette.purple.withAlphaComponent(0.24).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    let badgeFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    if let layout = DashboardReviewFileDiffPlainTextCache.layout(
      text: title,
      font: badgeFont,
      color: DashboardReviewFileDiffMonokaiPalette.purple
    ) {
      draw(layout: layout, x: rect.midX - floor(layout.typographicWidth / 2), lineRect: rect)
    }
  }

  private func threads(
    for row: DashboardReviewFileDiffRow,
    side: DashboardReviewFileDiffSide? = nil
  ) -> [DashboardReviewFileThreadAnchor] {
    let anchors = threadsByRowID[row.id] ?? []
    guard let side else { return anchors }
    return anchors.filter { $0.side == nil || $0.side == side }
  }
}
