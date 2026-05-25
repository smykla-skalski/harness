import AppKit
import HarnessMonitorKit

@MainActor
extension DashboardReviewFileDiffGridContentView {
  /// Handle a click in the diff: select the clicked row's line (extending the
  /// range from the existing anchor on shift-click) and report the resulting
  /// selection upward so it lands in navigation history.
  func handleSelectionClick(at point: NSPoint, extendingRange: Bool) {
    guard let row = row(at: point) else { return }
    if extendingRange, selectionAnchorRowID != nil {
      selectedRowID = row.id
    } else {
      selectionAnchorRowID = row.id
      selectedRowID = row.id
      selectionSide = resolvedSide(forRow: row, at: point)
    }
    let selection = currentLineSelection()
    // Mark the just-made selection as already scrolled so the value round-trip
    // back through the environment does not yank the viewport.
    lastScrolledLineSelection = selection
    incomingLineSelection = selection
    needsDisplay = true
    onSelectLines?(selection)
  }

  /// Update the selection when a context menu opens on `row`. The clicked row
  /// always becomes the menu's context. Matches Finder/Xcode: a context row
  /// inside the active multi-row selection keeps the whole range so the menu can
  /// act on it; a row outside the selection collapses to just that row. The
  /// collapse reports upward like a left-click so it stays put through the
  /// environment round-trip rather than reverting to the prior selection.
  func prepareContextMenuSelection(
    forContextRow row: DashboardReviewFileDiffRow,
    at point: NSPoint
  ) {
    contextMenuRowID = row.id
    needsDisplay = true
    guard !isRowInSelection(row) else { return }
    selectionAnchorRowID = row.id
    selectedRowID = row.id
    selectionSide = resolvedSide(forRow: row, at: point)
    let selection = currentLineSelection()
    lastScrolledLineSelection = selection
    incomingLineSelection = selection
    onSelectLines?(selection)
  }

  /// Translate the current anchor/focus row pair into a `ReviewLineSelection`
  /// on the active side, or `nil` when neither row carries a line there.
  func currentLineSelection() -> ReviewLineSelection? {
    guard let focusID = selectedRowID,
      let focus = rows.first(where: { $0.id == focusID })
    else {
      return nil
    }
    let anchor = selectionAnchorRowID.flatMap { id in rows.first { $0.id == id } } ?? focus
    let diffSide: DashboardReviewFileDiffSide = selectionSide == .right ? .new : .old
    guard let focusLine = focus.lineNumber(on: diffSide) else { return nil }
    let anchorLine = anchor.lineNumber(on: diffSide) ?? focusLine
    return ReviewLineSelection(start: anchorLine, end: focusLine, side: selectionSide)
  }

  /// Store an incoming selection (history/deep link) and resolve the highlight
  /// rows. Scrolling is deferred to `scrollToPendingLineSelectionIfNeeded` so it
  /// runs after the layout is rebuilt for the current width.
  func applyIncomingLineSelectionHighlight(_ selection: ReviewLineSelection?) {
    incomingLineSelection = selection
    guard let selection, let range = rowIndexRange(for: selection) else { return }
    selectionAnchorRowID = rows[range.lowerBound].id
    selectedRowID = rows[range.upperBound].id
    selectionSide = selection.side
  }

  /// Scroll the first row of the pending incoming selection into view, but only
  /// when the target changed, so unrelated updates never fight the reviewer's
  /// own scrolling.
  func scrollToPendingLineSelectionIfNeeded() {
    guard let selection = incomingLineSelection,
      lastScrolledLineSelection != selection,
      let range = rowIndexRange(for: selection)
    else {
      return
    }
    lastScrolledLineSelection = selection
    scrollRowIndexToVisible(range.lowerBound)
  }

  /// `true` when the row falls inside the highlighted anchor...focus range.
  func isRowInSelection(_ row: DashboardReviewFileDiffRow) -> Bool {
    guard let focusID = selectedRowID,
      let focusIndex = rowIndexByID[focusID],
      let rowIndex = rowIndexByID[row.id]
    else {
      return false
    }
    let anchorIndex = selectionAnchorRowID.flatMap { rowIndexByID[$0] } ?? focusIndex
    return rowIndex >= min(anchorIndex, focusIndex) && rowIndex <= max(anchorIndex, focusIndex)
  }

  /// Row-index range whose side line numbers fall within the selection.
  func rowIndexRange(for selection: ReviewLineSelection) -> ClosedRange<Int>? {
    let diffSide: DashboardReviewFileDiffSide = selection.side == .right ? .new : .old
    var lower: Int?
    var upper: Int?
    for (index, row) in rows.enumerated() {
      guard let line = row.lineNumber(on: diffSide), selection.contains(line: line) else {
        continue
      }
      if lower == nil { lower = index }
      upper = index
    }
    guard let first = lower, let last = upper else { return nil }
    return first...last
  }

  /// Resolve which diff side a click targets: the clicked column in split mode,
  /// otherwise the new side when the row has one (matching GitHub line anchors).
  private func resolvedSide(
    forRow row: DashboardReviewFileDiffRow,
    at point: NSPoint
  ) -> ReviewDiffSide {
    if viewMode == .split {
      let columnWidth = floor((bounds.width - 1) / 2)
      let onOldColumn = point.x < columnWidth
      if onOldColumn, row.oldLine != nil { return .left }
      if !onOldColumn, row.newLine != nil { return .right }
    }
    return row.newLine != nil ? .right : .left
  }

  private func scrollRowIndexToVisible(_ index: Int) {
    guard rows.indices.contains(index) else { return }
    let rect = layout.rowRect(index, width: bounds.width)
    // Pad vertically so the target row is not flush against the viewport edge.
    scrollToVisible(rect.insetBy(dx: 0, dy: -2 * rowHeight))
  }
}
