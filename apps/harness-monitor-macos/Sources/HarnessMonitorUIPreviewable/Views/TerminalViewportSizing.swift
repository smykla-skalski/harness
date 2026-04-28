import AppKit
import CoreText
import HarnessMonitorKit
import SwiftUI

enum TerminalViewportSizing {
  static let rowRange = 8...240
  static let colRange = 20...400
  static let minimumViewportHeight: CGFloat = 220
  static let idealViewportHeight: CGFloat = 320
  static let minimumControlsHeight: CGFloat = 220
  static let minimumMeasuredContentWidth: CGFloat = 160
  static let minimumMeasuredContentHeight: CGFloat = 96
  static let debounce = Duration.milliseconds(120)
  static let automaticResizeMinimumRowDelta = 2
  static let automaticResizeMinimumColDelta = 3
  static let contentInsets = CGSize(
    width: HarnessMonitorTheme.spacingMD * 2,
    height: HarnessMonitorTheme.spacingMD * 2
  )
  static let detailColumnHorizontalPadding = HarnessMonitorTheme.spacingLG * 2
  static let detailColumnVerticalPadding = HarnessMonitorTheme.spacingLG * 2
  static let liveSessionHeaderHeightEstimate: CGFloat = 80
  static let defaultLiveViewportSplitFraction: CGFloat = 0.5

  static func automaticResizeBaseline(
    serverSize: AgentTuiSize,
    pendingTarget: AgentTuiSize?,
    expectedSize: AgentTuiSize?
  ) -> AgentTuiSize {
    pendingTarget ?? expectedSize ?? serverSize
  }

  @MainActor
  static func estimatedStartSize(
    detailColumnSize: CGSize,
    fontScale: CGFloat,
    fallbackRows: Int
  ) -> AgentTuiSize {
    let estimatedViewportWidth = max(detailColumnSize.width - detailColumnHorizontalPadding, 0)
    let estimatedViewportHeight = max(
      (detailColumnSize.height
        - detailColumnVerticalPadding
        - liveSessionHeaderHeightEstimate) * defaultLiveViewportSplitFraction,
      0
    )
    let estimatedCols =
      terminalColumns(for: estimatedViewportWidth, fontScale: fontScale)
      ?? colRange.lowerBound
    let estimatedRows =
      terminalRows(for: estimatedViewportHeight, fontScale: fontScale)
      ?? fallbackRows
    return AgentTuiSize(
      rows: min(max(estimatedRows, rowRange.lowerBound), rowRange.upperBound),
      cols: min(max(estimatedCols, colRange.lowerBound), colRange.upperBound)
    )
  }

  @MainActor
  static func terminalSize(for viewportSize: CGSize, fontScale: CGFloat) -> AgentTuiSize? {
    let cellSize = measuredCellSize(for: fontScale)
    let usableWidth = viewportSize.width - contentInsets.width
    let usableHeight = viewportSize.height - contentInsets.height
    guard usableWidth >= minimumMeasuredContentWidth,
      usableHeight >= minimumMeasuredContentHeight
    else {
      return nil
    }
    let rawRows = Int(floor(usableHeight / cellSize.height))
    let rawCols = Int(floor(usableWidth / cellSize.width))
    guard rawRows > 0, rawCols > 0 else {
      return nil
    }
    return AgentTuiSize(
      rows: min(max(rawRows, rowRange.lowerBound), rowRange.upperBound),
      cols: min(max(rawCols, colRange.lowerBound), colRange.upperBound)
    )
  }

  @MainActor
  static func terminalColumns(for viewportWidth: CGFloat, fontScale: CGFloat) -> Int? {
    let usableWidth = viewportWidth - contentInsets.width
    guard usableWidth >= minimumMeasuredContentWidth else {
      return nil
    }
    let cellSize = measuredCellSize(for: fontScale)
    let rawCols = Int(floor(usableWidth / cellSize.width))
    guard rawCols > 0 else {
      return nil
    }
    return rawCols
  }

  @MainActor
  static func terminalRows(for viewportHeight: CGFloat, fontScale: CGFloat) -> Int? {
    let usableHeight = viewportHeight - contentInsets.height
    guard usableHeight >= minimumMeasuredContentHeight else {
      return nil
    }
    let cellSize = measuredCellSize(for: fontScale)
    let rawRows = Int(floor(usableHeight / cellSize.height))
    guard rawRows > 0 else {
      return nil
    }
    return rawRows
  }

  @MainActor
  static func contentWidth(for terminalSize: AgentTuiSize, fontScale: CGFloat) -> CGFloat {
    CGFloat(terminalSize.cols) * measuredCellSize(for: fontScale).width
  }

  static func stabilizedAutomaticSize(
    measured: AgentTuiSize,
    baseline: AgentTuiSize
  ) -> AgentTuiSize {
    AgentTuiSize(
      rows: stabilizedDimension(
        measured: measured.rows,
        baseline: baseline.rows,
        minimumDelta: automaticResizeMinimumRowDelta
      ),
      cols: stabilizedDimension(
        measured: measured.cols,
        baseline: baseline.cols,
        minimumDelta: automaticResizeMinimumColDelta
      )
    )
  }

  @MainActor
  private static func measuredCellSize(for fontScale: CGFloat) -> CGSize {
    let pointSize = 13 * max(fontScale, 0.78)
    let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    let width = max(monospacedGlyphAdvance(for: font) ?? 0, 1)
    let height = max(ceil(font.ascender - font.descender + font.leading), 1)
    return CGSize(width: width, height: height)
  }

  private static func monospacedGlyphAdvance(for font: NSFont) -> CGFloat? {
    var character: UniChar = 87
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
      return ("W" as NSString).size(withAttributes: [.font: font]).width
    }

    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    return advance.width
  }

  private static func stabilizedDimension(
    measured: Int,
    baseline: Int,
    minimumDelta: Int
  ) -> Int {
    abs(measured - baseline) >= minimumDelta ? measured : baseline
  }
}
