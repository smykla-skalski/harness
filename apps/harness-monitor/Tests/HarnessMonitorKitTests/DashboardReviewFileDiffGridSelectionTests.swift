import AppKit
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Dashboard review diff grid line selection")
struct DashboardReviewFileDiffGridSelectionTests {
  private func makeView(
    rows: [DashboardReviewFileDiffRow]
  ) -> DashboardReviewFileDiffGridContentView {
    let view = DashboardReviewFileDiffGridContentView(frame: .zero)
    view.rows = rows
    view.rowIndexByID = Dictionary(
      uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) }
    )
    return view
  }

  private func row(
    _ id: Int,
    old: Int?,
    new: Int?,
    kind: DashboardReviewFileDiffRow.Kind = .context
  ) -> DashboardReviewFileDiffRow {
    DashboardReviewFileDiffRow(
      id: id,
      kind: kind,
      oldLine: old,
      newLine: new,
      diffPosition: nil,
      text: "code",
      contextGap: nil
    )
  }

  @Test("maps a right-side line range to the matching row indices")
  func rowIndexRangeRightSide() {
    let view = makeView(rows: [
      row(0, old: 1, new: 1),
      row(1, old: 2, new: 2),
      row(2, old: nil, new: 3, kind: .addition),
      row(3, old: 3, new: 4),
    ])
    #expect(view.rowIndexRange(for: ReviewLineSelection(start: 2, end: 3, side: .right)) == 1...2)
  }

  @Test("maps a left-side line to the old-number row")
  func rowIndexRangeLeftSide() {
    let view = makeView(rows: [
      row(0, old: 1, new: 1),
      row(1, old: 2, new: nil, kind: .deletion),
      row(2, old: 3, new: 2),
    ])
    #expect(view.rowIndexRange(for: ReviewLineSelection(line: 2, side: .left)) == 1...1)
  }

  @Test("returns nil when no row carries a line in the range")
  func rowIndexRangeNoMatch() {
    let view = makeView(rows: [row(0, old: 1, new: 1), row(1, old: 2, new: 2)])
    #expect(view.rowIndexRange(for: ReviewLineSelection(line: 99, side: .right)) == nil)
  }

  @Test("isRowInSelection covers the inclusive anchor...focus span")
  func isRowInSelectionSpan() {
    let rows = [row(0, old: 1, new: 1), row(1, old: 2, new: 2), row(2, old: 3, new: 3)]
    let view = makeView(rows: rows)
    view.selectionAnchorRowID = 0
    view.selectedRowID = 2
    #expect(view.isRowInSelection(rows[0]))
    #expect(view.isRowInSelection(rows[1]))
    #expect(view.isRowInSelection(rows[2]))
  }

  @Test("isRowInSelection is false with no focus row")
  func isRowInSelectionEmpty() {
    let rows = [row(0, old: 1, new: 1)]
    let view = makeView(rows: rows)
    #expect(!view.isRowInSelection(rows[0]))
  }

  @Test("currentLineSelection derives lines from anchor and focus on the side")
  func currentLineSelectionDerivesRange() {
    let rows = [row(0, old: 1, new: 10), row(1, old: 2, new: 11), row(2, old: 3, new: 12)]
    let view = makeView(rows: rows)
    view.selectionSide = .right
    view.selectionAnchorRowID = 0
    view.selectedRowID = 2
    #expect(view.currentLineSelection() == ReviewLineSelection(start: 10, end: 12, side: .right))
  }

  @Test("applyIncomingLineSelectionHighlight resolves anchor and focus rows")
  func applyIncomingHighlightResolvesRows() {
    let rows = [row(0, old: 1, new: 10), row(1, old: 2, new: 11), row(2, old: 3, new: 12)]
    let view = makeView(rows: rows)
    view.applyIncomingLineSelectionHighlight(
      ReviewLineSelection(start: 11, end: 12, side: .right)
    )
    #expect(view.selectionAnchorRowID == 1)
    #expect(view.selectedRowID == 2)
    #expect(view.selectionSide == .right)
  }
}
