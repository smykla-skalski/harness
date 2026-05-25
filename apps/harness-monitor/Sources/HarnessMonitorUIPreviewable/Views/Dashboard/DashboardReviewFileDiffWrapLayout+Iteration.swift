import Foundation

extension DashboardReviewFileDiffWrapLayout {
  struct VisualLineContext {
    let text: String
    let positions: [String.Index]
    let leadingIndentColumns: Int
  }

  struct BreakResolutionContext {
    let text: String
    let positions: [String.Index]
    let startOffset: Int
    let characterCount: Int
    let forcedBreak: Int
    let strategy: Strategy
  }

  struct IterationContext {
    let availableColumns: Int
    let lineContext: VisualLineContext
  }

  static func makeIterationContext(
    text: String,
    positions: [String.Index],
    resolvedCharacterLimit: Int,
    firstLine: Bool,
    currentIndentColumns: Int
  ) -> IterationContext {
    let availableColumns = availableColumns(
      resolvedCharacterLimit: resolvedCharacterLimit,
      firstLine: firstLine,
      currentIndentColumns: currentIndentColumns
    )
    return IterationContext(
      availableColumns: availableColumns,
      lineContext: VisualLineContext(
        text: text,
        positions: positions,
        leadingIndentColumns: firstLine ? 0 : currentIndentColumns
      )
    )
  }

  static func appendRemainingLine(
    _ visualLines: inout [DashboardReviewFileDiffWrappedVisualLine],
    context: VisualLineContext,
    startOffset: Int,
    characterCount: Int
  ) {
    appendVisualLine(
      &visualLines,
      context: context,
      startOffset: startOffset,
      endOffset: characterCount
    )
  }
}
