import AppKit
import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFileDiffGrid: NSViewRepresentable {
  let document: DashboardReviewFileDiffDocument
  let viewMode: FilesViewMode
  let fontScale: CGFloat
  let threads: [DashboardReviewFileThreadAnchor]
  let repositoryFullName: String?

  init(
    document: DashboardReviewFileDiffDocument,
    viewMode: FilesViewMode,
    fontScale: CGFloat,
    threads: [DashboardReviewFileThreadAnchor] = [],
    repositoryFullName: String? = nil
  ) {
    self.document = document
    self.viewMode = viewMode
    self.fontScale = fontScale
    self.threads = threads
    self.repositoryFullName = repositoryFullName
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = DashboardReviewFileDiffGridContentView()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let contentView =
      scrollView.documentView as? DashboardReviewFileDiffGridContentView
      ?? DashboardReviewFileDiffGridContentView()
    if scrollView.documentView !== contentView {
      scrollView.documentView = contentView
    }
    contentView.configure(
      document: document,
      viewMode: viewMode,
      fontScale: fontScale,
      threads: threads,
      repositoryFullName: repositoryFullName
    )
    let size = contentView.preferredSize(containerWidth: scrollView.contentSize.width)
    if contentView.frame.size != size {
      contentView.setFrameSize(size)
    }
  }

  static func viewportHeight(rowCount: Int, fontScale: CGFloat) -> CGFloat {
    let pointSize = DashboardReviewDiffTypography.pointSize(fontScale: fontScale)
    let rowHeight = max(18, pointSize + 7)
    let contentHeight = CGFloat(max(rowCount, 1)) * rowHeight + 2
    return min(max(contentHeight, 84), 720)
  }

  final class Coordinator {}
}

@MainActor
final class DashboardReviewFileDiffGridContentView: NSView {
  var rows: [DashboardReviewFileDiffRow] = []
  private var viewMode: FilesViewMode = .unified
  private var codeLanguage: HarnessCodeLanguage = .generic
  private var longestCodeCharacterCount = 0
  var threadsByRowID: [Int: [DashboardReviewFileThreadAnchor]] = [:]
  var selectedRowID: Int?
  var documentPath = ""
  var headRefOid = ""
  var repositoryFullName: String?
  private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  var rowHeight: CGFloat = 19
  private var characterWidth: CGFloat = 7.2
  var contextMenuRowID: Int?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func configure(
    document: DashboardReviewFileDiffDocument,
    viewMode: FilesViewMode,
    fontScale: CGFloat,
    threads: [DashboardReviewFileThreadAnchor],
    repositoryFullName: String?
  ) {
    let nextFont = NSFont.monospacedSystemFont(
      ofSize: DashboardReviewDiffTypography.pointSize(fontScale: fontScale),
      weight: .regular
    )
    let nextLanguage = HarnessCodeLanguage(reviewLanguage: document.language)
    rows = document.rows
    self.viewMode = viewMode
    codeLanguage = nextLanguage
    longestCodeCharacterCount = document.longestCodeCharacterCount
    threadsByRowID = Self.buildThreadMap(rows: document.rows, threads: threads)
    selectedRowID = selectedRowID.flatMap { selected in
      document.rows.contains(where: { $0.id == selected }) ? selected : nil
    }
    documentPath = document.path
    headRefOid = document.headRefOid
    self.repositoryFullName = repositoryFullName
    font = nextFont
    rowHeight = max(18, font.pointSize + 7)
    characterWidth = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
    needsDisplay = true
  }

  func preferredSize(containerWidth: CGFloat) -> CGSize {
    let cappedCharacters = CGFloat(min(max(longestCodeCharacterCount, 80), 520))
    let codeWidth = cappedCharacters * characterWidth
    let width: CGFloat =
      switch viewMode {
      case .unified:
        max(containerWidth, 130 + codeWidth)
      case .split:
        max(containerWidth, 2 * (96 + codeWidth) + 18)
      }
    let height = CGFloat(max(rows.count, 1)) * rowHeight + 2
    return CGSize(width: ceil(width), height: ceil(height))
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !rows.isEmpty else { return }
    let firstRow = max(Int(floor(dirtyRect.minY / rowHeight)), 0)
    let lastRow = min(Int(ceil(dirtyRect.maxY / rowHeight)), rows.count - 1)
    guard firstRow <= lastRow else { return }
    let visibleCount = lastRow - firstRow + 1
    let interval =
      rows.count >= ReviewFilesPerf.renderSignpostThresholdLines
      ? ReviewFilesPerf.beginAppKitDraw(rowCount: visibleCount)
      : nil
    defer {
      if let interval {
        ReviewFilesPerf.end(interval)
      }
    }
    for index in firstRow...lastRow {
      let rect = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
      draw(row: rows[index], in: rect)
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    selectedRowID = row(at: convert(event.locationInWindow, from: nil))?.id
    needsDisplay = true
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
      copySelectedSourceLine()
      return
    }
    super.keyDown(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return nil }
    contextMenuRowID = row.id
    selectedRowID = row.id
    needsDisplay = true
    let menu = NSMenu()
    addMenuItem("Copy Source Line", action: #selector(copyContextSourceLine), to: menu)
    addMenuItem("Copy Line Anchor", action: #selector(copyContextLineAnchor), to: menu)
    if githubPermalink(for: row) != nil {
      addMenuItem("Copy GitHub Permalink", action: #selector(copyContextPermalink), to: menu)
    }
    if let url = threadsByRowID[row.id]?.compactMap(\.url).first {
      addMenuItem("Copy Thread URL", action: #selector(copyContextThreadURL(_:)), to: menu)
      menu.item(at: menu.items.count - 1)?.representedObject = url
    }
    menu.addItem(.separator())
    addMenuItem("Copy File Path", action: #selector(copyFilePath), to: menu)
    return menu
  }

  private func draw(row: DashboardReviewFileDiffRow, in rect: NSRect) {
    fillBackground(for: row.kind, in: rect)
    if row.id == selectedRowID {
      NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
      rect.fill()
    }
    switch viewMode {
    case .unified:
      drawUnified(row: row, in: rect)
    case .split:
      drawSplit(row: row, in: rect)
    }
  }

  private func drawUnified(row: DashboardReviewFileDiffRow, in rect: NSRect) {
    let y = textY(in: rect)
    if row.kind == .hunk || row.kind == .metadata || row.kind == .contextGap {
      drawControlText(row.text, x: 12, y: y, kind: row.kind)
      return
    }
    drawThreadBadge(for: row, x: 7, y: y)
    drawLineNumber(row.oldLine, rightX: 42, y: y)
    drawLineNumber(row.newLine, rightX: 84, y: y)
    drawString(row.unifiedPrefix, x: 101, y: y, color: prefixColor(for: row.kind))
    attributedCode(for: row).draw(at: NSPoint(x: 120, y: y))
  }

  private func drawSplit(row: DashboardReviewFileDiffRow, in rect: NSRect) {
    if row.kind == .hunk || row.kind == .metadata || row.kind == .contextGap {
      drawControlText(row.text, x: 12, y: textY(in: rect), kind: row.kind)
      return
    }
    let columnWidth = floor((bounds.width - 1) / 2)
    NSColor.separatorColor.setFill()
    NSRect(x: columnWidth, y: rect.minY, width: 1, height: rect.height).fill()
    drawSplitSide(row: row, side: .old, x: 0, width: columnWidth, rect: rect)
    drawSplitSide(row: row, side: .new, x: columnWidth + 1, width: columnWidth, rect: rect)
  }

  private func drawSplitSide(
    row: DashboardReviewFileDiffRow,
    side: DashboardReviewFileDiffSide,
    x: CGFloat,
    width: CGFloat,
    rect: NSRect
  ) {
    guard isRow(row, visibleOn: side) else { return }
    let y = textY(in: rect)
    let line = side == .old ? row.oldLine : row.newLine
    let prefix = splitPrefix(for: row.kind, side: side)
    drawThreadBadge(for: row, side: side, x: x + 7, y: y)
    drawLineNumber(line, rightX: x + 42, y: y)
    drawString(prefix, x: x + 58, y: y, color: prefixColor(for: row.kind))
    attributedCode(for: row).draw(
      in: NSRect(x: x + 76, y: y, width: width - 82, height: rowHeight)
    )
  }

  private func attributedCode(for row: DashboardReviewFileDiffRow) -> NSAttributedString {
    DashboardReviewFileDiffHighlightCache.attributed(
      text: row.text,
      language: codeLanguage,
      font: font
    )
  }

  private func fillBackground(for kind: DashboardReviewFileDiffRow.Kind, in rect: NSRect) {
    switch kind {
    case .addition:
      NSColor.systemGreen.withAlphaComponent(0.13).setFill()
    case .deletion:
      NSColor.systemRed.withAlphaComponent(0.12).setFill()
    case .hunk:
      NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
    case .contextGap:
      NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
    case .metadata:
      NSColor.systemOrange.withAlphaComponent(0.10).setFill()
    case .context:
      NSColor.textBackgroundColor.withAlphaComponent(0.22).setFill()
    }
    rect.fill()
  }

  private func drawLineNumber(_ number: Int?, rightX: CGFloat, y: CGFloat) {
    guard let number else { return }
    let text = "\(number)" as NSString
    let attributes = dimAttributes
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: rightX - size.width, y: y), withAttributes: attributes)
  }

  private func drawControlText(
    _ text: String,
    x: CGFloat,
    y: CGFloat,
    kind: DashboardReviewFileDiffRow.Kind
  ) {
    let color: NSColor =
      switch kind {
      case .contextGap:
        .tertiaryLabelColor
      case .metadata:
        .systemOrange
      case .hunk:
        .secondaryLabelColor
      case .addition, .context, .deletion:
        .labelColor
      }
    drawString(text, x: x, y: y, color: color)
  }

  private func drawString(_ text: String, x: CGFloat, y: CGFloat, color: NSColor) {
    (text as NSString).draw(
      at: NSPoint(x: x, y: y),
      withAttributes: [.font: font, .foregroundColor: color]
    )
  }

  private func textY(in rect: NSRect) -> CGFloat {
    rect.minY + max(2, floor((rowHeight - font.pointSize) / 2) - 1)
  }

  private var dimAttributes: [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
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
    case .addition: .systemGreen
    case .deletion: .systemRed
    case .context: .tertiaryLabelColor
    case .contextGap, .hunk, .metadata: .secondaryLabelColor
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
    y: CGFloat
  ) {
    let anchors = threads(for: row, side: side)
    guard !anchors.isEmpty else { return }
    let title = anchors.count == 1 ? anchors[0].badgeTitle : "\(anchors.count)"
    let rect = NSRect(x: x, y: y - 1, width: 20, height: 15)
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    (title as NSString).draw(
      at: NSPoint(x: rect.midX - 3.5, y: rect.minY + 1),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.controlAccentColor,
      ]
    )
  }

  private func threads(
    for row: DashboardReviewFileDiffRow,
    side: DashboardReviewFileDiffSide? = nil
  ) -> [DashboardReviewFileThreadAnchor] {
    let anchors = threadsByRowID[row.id] ?? []
    guard let side else { return anchors }
    return anchors.filter { $0.side == nil || $0.side == side }
  }

  private static func buildThreadMap(
    rows: [DashboardReviewFileDiffRow],
    threads: [DashboardReviewFileThreadAnchor]
  ) -> [Int: [DashboardReviewFileThreadAnchor]] {
    guard !threads.isEmpty else { return [:] }
    var out: [Int: [DashboardReviewFileThreadAnchor]] = [:]
    for row in rows {
      let matched = threads.filter { row.matches(anchor: $0) }
      if !matched.isEmpty {
        out[row.id] = matched
      }
    }
    return out
  }

}
