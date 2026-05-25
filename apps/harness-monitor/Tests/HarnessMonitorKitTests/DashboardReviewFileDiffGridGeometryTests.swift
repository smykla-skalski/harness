import AppKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file diff grid geometry")
struct DashboardReviewFileDiffGridGeometryTests {
  @Test("unified budget reserves the draw inset plus one character")
  func unifiedBudgetReservesDrawInsetAndOneCharacter() {
    let characterWidth: CGFloat = 7.5
    let budget = DashboardReviewFileDiffGridGeometry.unifiedCodeColumnWidth(
      contentWidth: 1000,
      characterWidth: characterWidth
    )
    let inset = DashboardReviewFileDiffGridGeometry.unifiedCodeLeftInset
    #expect(budget == 1000 - inset - characterWidth)
  }

  @Test("split budget reserves the draw inset plus one character")
  func splitBudgetReservesDrawInsetAndOneCharacter() {
    let characterWidth: CGFloat = 7.5
    let budget = DashboardReviewFileDiffGridGeometry.splitCodeColumnWidth(
      columnWidth: 500,
      characterWidth: characterWidth
    )
    let inset = DashboardReviewFileDiffGridGeometry.splitCodeLeftInset
    #expect(budget == 500 - inset - characterWidth)
  }

  @Test("both modes reserve the same one-character right margin")
  func bothModesShareOneCharacterRightMargin() {
    let characterWidth: CGFloat = 9
    let unifiedBudget = DashboardReviewFileDiffGridGeometry.unifiedCodeColumnWidth(
      contentWidth: 1000,
      characterWidth: characterWidth
    )
    let splitBudget = DashboardReviewFileDiffGridGeometry.splitCodeColumnWidth(
      columnWidth: 500,
      characterWidth: characterWidth
    )
    let unifiedReserve =
      1000 - unifiedBudget - DashboardReviewFileDiffGridGeometry.unifiedCodeLeftInset
    let splitReserve =
      500 - splitBudget - DashboardReviewFileDiffGridGeometry.splitCodeLeftInset
    #expect(unifiedReserve == characterWidth)
    #expect(splitReserve == characterWidth)
  }

  @Test("budget never collapses below one character at tiny widths")
  func budgetFloorsAtOneCharacter() {
    let characterWidth: CGFloat = 8
    let unified = DashboardReviewFileDiffGridGeometry.unifiedCodeColumnWidth(
      contentWidth: 10,
      characterWidth: characterWidth
    )
    let split = DashboardReviewFileDiffGridGeometry.splitCodeColumnWidth(
      columnWidth: 10,
      characterWidth: characterWidth
    )
    #expect(unified == characterWidth)
    #expect(split == characterWidth)
  }

  @Test("character advance is positive and run-length invariant")
  func characterAdvanceIsRunLengthInvariant() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let advance = DashboardReviewDiffTypography.characterAdvance(for: font)
    #expect(advance > 0)
    // A monospaced run's width is the per-character advance times its length,
    // so the helper's averaged value must match a single glyph's advance.
    let single = ("0" as NSString).size(withAttributes: [.font: font]).width
    #expect(abs(advance - single) < 0.5)
  }
}
