import AppKit
import CoreGraphics
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file diff thread layout")
struct DashboardReviewFileDiffThreadLayoutTests {
  @Test("with no cards the layout is a flat fixed-row grid")
  func noCardsMatchesFlatLayout() {
    let layout = DashboardReviewFileDiffThreadLayout(rowCount: 5, rowHeight: 20)
    #expect(layout.rowTop(0) == 0)
    #expect(layout.rowTop(3) == 60)
    #expect(layout.totalHeight == 102)
    #expect(layout.rowIndex(atY: 65) == 3)
    #expect(!layout.hasCard(2))
    #expect(layout.cardRect(2, width: 100) == nil)
  }

  @Test("a card reserves a gap and shifts every following row down")
  func cardShiftsSubsequentRows() {
    let layout = DashboardReviewFileDiffThreadLayout(
      rowCount: 4,
      rowHeight: 20,
      cardHeights: [1: 50]
    )
    #expect(layout.rowTop(0) == 0)
    #expect(layout.rowTop(1) == 20)
    // Row 2 sits below row 1 (20) + row 1 height (20) + the 50pt card gap.
    #expect(layout.rowTop(2) == 90)
    #expect(layout.rowTop(3) == 110)
    #expect(layout.totalHeight == 132)
    #expect(layout.hasCard(1))
    #expect(!layout.hasCard(0))
  }

  @Test("the card rect sits directly below its owning row")
  func cardRectSitsBelowRow() {
    let layout = DashboardReviewFileDiffThreadLayout(
      rowCount: 4,
      rowHeight: 20,
      cardHeights: [1: 50]
    )
    let rect = layout.cardRect(1, width: 120)
    #expect(rect == CGRect(x: 0, y: 40, width: 120, height: 50))
    #expect(layout.cardRect(0, width: 120) == nil)
  }

  @Test("a Y inside the card gap maps to the owning row for draw culling")
  func rowIndexInsideCardGapReturnsOwningRow() {
    let layout = DashboardReviewFileDiffThreadLayout(
      rowCount: 4,
      rowHeight: 20,
      cardHeights: [1: 50]
    )
    // Card gap spans y in [40, 90); the owning row is index 1.
    #expect(layout.rowIndex(atY: 50) == 1)
    #expect(layout.rowIndex(atY: 95) == 2)
  }

  @Test("text-line hit testing returns nil inside the card gap")
  func rowIndexHittingTextLineNilInGap() {
    let layout = DashboardReviewFileDiffThreadLayout(
      rowCount: 4,
      rowHeight: 20,
      cardHeights: [1: 50]
    )
    #expect(layout.rowIndexHittingTextLine(atY: 25) == 1)
    #expect(layout.rowIndexHittingTextLine(atY: 50) == nil)
    #expect(layout.rowIndexHittingTextLine(atY: 95) == 2)
  }

  @Test("visible row range clips to the dirty rect across a card gap")
  func visibleRowRangeClipsToRect() {
    let layout = DashboardReviewFileDiffThreadLayout(
      rowCount: 4,
      rowHeight: 20,
      cardHeights: [1: 50]
    )
    let range = layout.visibleRowRange(in: CGRect(x: 0, y: 85, width: 100, height: 30))
    #expect(range == 1...3)
  }

  @Test("multiple cards accumulate their gaps in order")
  func multipleCardsAccumulate() {
    let layout = DashboardReviewFileDiffThreadLayout(
      rowCount: 4,
      rowHeight: 10,
      cardHeights: [0: 30, 2: 40]
    )
    #expect(layout.rowTop(0) == 0)
    #expect(layout.rowTop(1) == 40)
    #expect(layout.rowTop(2) == 50)
    #expect(layout.rowTop(3) == 100)
    #expect(layout.totalHeight == 112)
  }

  @Test("variable text heights shift following rows and card anchors")
  func variableTextHeightsShiftFollowingRows() {
    let layout = DashboardReviewFileDiffThreadLayout(
      rowCount: 3,
      rowHeight: 20,
      rowHeights: [1: 60],
      cardHeights: [1: 40]
    )

    #expect(layout.rowTop(0) == 0)
    #expect(layout.rowTop(1) == 20)
    #expect(layout.textHeight(1) == 60)
    #expect(layout.cardRect(1, width: 120) == CGRect(x: 0, y: 80, width: 120, height: 40))
    #expect(layout.rowTop(2) == 120)
    #expect(layout.totalHeight == 142)
  }
}

@Suite("Dashboard review diff typography")
struct DashboardReviewDiffTypographyTests {
  @Test("layout metrics lift text slightly to balance row whitespace")
  func layoutMetricsLiftTextForOpticalCentering() {
    let font = DashboardReviewDiffTypography.appKitFont(for: 1)
    let metrics = DashboardReviewDiffTypography.layoutMetrics(for: font)

    #expect(metrics.lineTextHeight == 15)
    #expect(metrics.rowHeight == 21)
    #expect(metrics.textTopInset == 2)
    #expect(metrics.textBottomInset == 4)
  }

  @Test("thread badge rect is vertically centered in the row band")
  func threadBadgeRectIsCentered() {
    let font = DashboardReviewDiffTypography.appKitFont(for: 1)
    let metrics = DashboardReviewDiffTypography.layoutMetrics(for: font)
    let badgeRect = metrics.badgeRect(
      in: CGRect(x: 0, y: 0, width: 120, height: metrics.rowHeight),
      x: 7
    )

    #expect(badgeRect == CGRect(x: 7, y: 3, width: 20, height: 15))
  }

  @Test("glyph-bound baseline centers prose and key rows in the same band")
  @MainActor
  func glyphBoundBaselineCentersDifferentRowTexts() {
    let font = DashboardReviewDiffTypography.appKitFont(for: 1)
    let metrics = DashboardReviewDiffTypography.layoutMetrics(for: font)
    let rowRect = CGRect(x: 0, y: 0, width: 300, height: metrics.rowHeight)

    let prose = DashboardReviewFileDiffPlainTextCache.layout(
      text: "Rules defines inbound timeout configurations.",
      font: font,
      color: .white
    )
    let key = DashboardReviewFileDiffPlainTextCache.layout(
      text: "items:",
      font: font,
      color: .white
    )
    #expect(prose != nil)
    #expect(key != nil)

    if let prose, let key {
      let proseBaselineY = metrics.baselineY(for: prose.glyphBounds, in: rowRect)
      let proseTop = proseBaselineY - prose.glyphBounds.maxY
      let proseBottom = rowRect.height - (proseBaselineY - prose.glyphBounds.minY)
      let keyBaselineY = metrics.baselineY(for: key.glyphBounds, in: rowRect)
      let keyTop = keyBaselineY - key.glyphBounds.maxY
      let keyBottom = rowRect.height - (keyBaselineY - key.glyphBounds.minY)

      #expect(abs(proseTop - proseBottom) <= 1)
      #expect(abs(keyTop - keyBottom) <= 1)
    }
  }

  @Suite("Dashboard review file diff rendering semantics")
  struct DashboardReviewFileDiffRenderingSemanticsTests {
    @Test("wrapped comment continuations keep comment highlighting")
    @MainActor
    func wrappedCommentContinuationKeepsCommentColor() {
      let row = DashboardReviewFileDiffRow(
        id: 0,
        kind: .addition,
        oldLine: nil,
        newLine: 1,
        diffPosition: 1,
        text: "// one two three four five six seven eight nine ten",
        contextGap: nil
      )
      let wrappedLayout = DashboardReviewFileDiffWrapLayout.layout(
        row: row,
        language: .go,
        softWrapEnabled: true,
        characterLimit: 18
      )
      let font = DashboardReviewDiffTypography.appKitFont(for: 1)
      let continuation = wrappedLayout.visualLines[1]
      let lineLayout = DashboardReviewFileDiffHighlightCache.layout(
        visualLine: continuation,
        highlightSpans: wrappedLayout.highlightSpans,
        font: font
      )
      let color =
        lineLayout.attributedString.attribute(
          .foregroundColor,
          at: continuation.leadingIndentColumns + 1,
          effectiveRange: nil
        ) as? NSColor

      #expect(color == DashboardReviewFileDiffMonokaiPalette.comment)
    }

    @Test("split additions and deletions keep the opposite pane neutral")
    func splitChangedRowsOnlyTintTheChangedSide() {
      #expect(
        DashboardReviewFileDiffSplitBackground.rowKind(for: .addition, side: .old) == .context)
      #expect(
        DashboardReviewFileDiffSplitBackground.rowKind(for: .addition, side: .new) == .addition)
      #expect(
        DashboardReviewFileDiffSplitBackground.rowKind(for: .deletion, side: .old) == .deletion)
      #expect(
        DashboardReviewFileDiffSplitBackground.rowKind(for: .deletion, side: .new) == .context)
    }

    @Test("wrapped prose string continuations keep string highlighting")
    @MainActor
    func wrappedProseStringContinuationKeepsStringColor() {
      let row = DashboardReviewFileDiffRow(
        id: 0,
        kind: .addition,
        oldLine: nil,
        newLine: 1,
        diffPosition: 1,
        text: #"        "Distribution of resource counts per xDS snapshot by resource type.","#,
        contextGap: nil
      )
      let wrappedLayout = DashboardReviewFileDiffWrapLayout.layout(
        row: row,
        language: .go,
        softWrapEnabled: true,
        characterLimit: 18
      )
      let font = DashboardReviewDiffTypography.appKitFont(for: 1)
      let continuation = wrappedLayout.visualLines[1]
      let lineLayout = DashboardReviewFileDiffHighlightCache.layout(
        visualLine: continuation,
        highlightSpans: wrappedLayout.highlightSpans,
        font: font
      )
      let color =
        lineLayout.attributedString.attribute(
          .foregroundColor,
          at: continuation.leadingIndentColumns + 1,
          effectiveRange: nil
        ) as? NSColor

      #expect(color == DashboardReviewFileDiffMonokaiPalette.yellow)
    }
  }
}
