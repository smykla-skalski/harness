import AppKit
import CoreText

enum DashboardReviewFileDiffSplitBackground {
  static func rowKind(
    for kind: DashboardReviewFileDiffRow.Kind,
    side: DashboardReviewFileDiffSide
  ) -> DashboardReviewFileDiffRow.Kind {
    switch (kind, side) {
    case (.addition, .old), (.deletion, .new):
      .context
    default:
      kind
    }
  }
}

@MainActor
extension DashboardReviewFileDiffGridContentView {
  private struct SplitSideGeometry {
    let side: DashboardReviewFileDiffSide
    let x: CGFloat
    let width: CGFloat
  }

  private struct CodeDrawingRegion {
    let x: CGFloat
    let maxX: CGFloat
    let rect: NSRect

    var clip: NSRect {
      NSRect(
        x: x,
        y: rect.minY,
        width: max(maxX - x, 0),
        height: rect.height
      )
    }
  }

  func draw(
    row: DashboardReviewFileDiffRow,
    wrappedLayout: DashboardReviewFileDiffWrappedRowLayout,
    in rect: NSRect
  ) {
    fillBackground(for: row, in: rect)
    if isRowInSelection(row) {
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
      row.unifiedPrefix, x: 101, lineRect: firstLineRect, color: prefixColor(for: row.kind))
    drawCodeLines(
      wrappedLayout.visualLines,
      highlightSpans: wrappedLayout.highlightSpans,
      rowID: row.id,
      region: .init(
        x: DashboardReviewFileDiffGridGeometry.unifiedCodeLeftInset,
        maxX: bounds.width,
        rect: rect
      )
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
      geometry: .init(side: .old, x: 0, width: columnWidth),
      rect: rect
    )
    drawSplitSide(
      row: row,
      wrappedLayout: wrappedLayout,
      geometry: .init(side: .new, x: columnWidth + 1, width: columnWidth),
      rect: rect
    )
  }

  private func drawSplitSide(
    row: DashboardReviewFileDiffRow,
    wrappedLayout: DashboardReviewFileDiffWrappedRowLayout,
    geometry: SplitSideGeometry,
    rect: NSRect
  ) {
    guard isRow(row, visibleOn: geometry.side) else { return }
    let firstLineRect = visualLineRect(in: rect, lineIndex: 0)
    let line = geometry.side == .old ? row.oldLine : row.newLine
    let prefix = splitPrefix(for: row.kind, side: geometry.side)
    drawThreadBadge(for: row, side: geometry.side, x: geometry.x + 7, lineRect: firstLineRect)
    drawLineNumber(line, rightX: geometry.x + 42, lineRect: firstLineRect)
    drawPlainText(
      prefix,
      x: geometry.x + 58,
      lineRect: firstLineRect,
      color: prefixColor(for: row.kind)
    )
    drawCodeLines(
      wrappedLayout.visualLines,
      highlightSpans: wrappedLayout.highlightSpans,
      rowID: row.id,
      region: .init(
        x: geometry.x + DashboardReviewFileDiffGridGeometry.splitCodeLeftInset,
        maxX: geometry.x + geometry.width,
        rect: rect
      )
    )
  }

  private func codeLayout(
    rowID: Int,
    lineIndex: Int,
    visualLine: DashboardReviewFileDiffWrappedVisualLine,
    highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan]
  ) -> DashboardReviewFileDiffTextLineLayout {
    let sourceOffsets = visualLine.sourceOffsets ?? 0..<visualLine.text.count
    let key = SemanticCodeLineKey(
      rowID: rowID,
      lineIndex: lineIndex,
      leadingIndentColumns: visualLine.leadingIndentColumns,
      startOffset: sourceOffsets.lowerBound,
      endOffset: sourceOffsets.upperBound,
      pointSize: font.pointSize
    )
    if let cached = semanticCodeLineCache[key] {
      return cached
    }
    let layout: DashboardReviewFileDiffTextLineLayout
    if !highlightSpans.isEmpty, visualLine.sourceOffsets != nil {
      layout = DashboardReviewFileDiffHighlightCache.layout(
        visualLine: visualLine,
        highlightSpans: highlightSpans,
        font: font
      )
    } else {
      layout = DashboardReviewFileDiffHighlightCache.layout(
        text: visualLine.displayText,
        language: codeLanguage,
        font: font
      )
    }
    semanticCodeLineCache[key] = layout
    return layout
  }

  private func fillBackground(
    for row: DashboardReviewFileDiffRow,
    in rect: NSRect
  ) {
    switch viewMode {
    case .unified:
      fillBackground(for: row.kind, in: rect)
    case .split:
      if row.kind == .hunk || row.kind == .metadata || row.kind == .contextGap {
        fillBackground(for: row.kind, in: rect)
      } else {
        let columnWidth = floor((bounds.width - 1) / 2)
        fillBackground(
          for: DashboardReviewFileDiffSplitBackground.rowKind(for: row.kind, side: .old),
          in: NSRect(x: 0, y: rect.minY, width: columnWidth, height: rect.height)
        )
        fillBackground(
          for: DashboardReviewFileDiffSplitBackground.rowKind(for: row.kind, side: .new),
          in: NSRect(
            x: columnWidth + 1,
            y: rect.minY,
            width: columnWidth,
            height: rect.height
          )
        )
      }
    }
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
    _ lines: [DashboardReviewFileDiffWrappedVisualLine],
    highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan],
    rowID: Int,
    region: CodeDrawingRegion
  ) {
    // Clip code to its column as a hard backstop: even if a wrapped line were
    // mismeasured, a glyph can never bleed across the split divider or past
    // the viewport edge. With the column-budget engine this is rarely hit.
    for (index, line) in lines.enumerated() {
      let lineRect = visualLineRect(in: region.rect, lineIndex: index)
      draw(
        layout: codeLayout(
          rowID: rowID,
          lineIndex: index,
          visualLine: line,
          highlightSpans: highlightSpans
        ),
        x: region.x,
        lineRect: lineRect,
        clip: region.clip
      )
    }
  }

  private func draw(
    layout: DashboardReviewFileDiffTextLineLayout,
    x: CGFloat,
    lineRect: NSRect,
    clip: NSRect? = nil
  ) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    if let clip {
      context.clip(to: clip)
    }
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
