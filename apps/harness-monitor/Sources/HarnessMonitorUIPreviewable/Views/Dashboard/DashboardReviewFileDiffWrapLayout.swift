import Foundation

struct DashboardReviewFileDiffWrappedHighlightSpan: Equatable {
  let range: Range<Int>
  let kind: HarnessCodeToken.Kind
}

struct DashboardReviewFileDiffWrappedVisualLine: Equatable {
  let text: String
  let leadingIndentColumns: Int
  let sourceOffsets: Range<Int>?

  var displayText: String {
    String(repeating: " ", count: leadingIndentColumns) + text
  }
}

struct DashboardReviewFileDiffWrappedRowLayout: Equatable {
  let visualLines: [DashboardReviewFileDiffWrappedVisualLine]
  let highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan]

  var displayLines: [String] {
    if visualLines.isEmpty {
      return [""]
    }
    return visualLines.map(\.displayText)
  }

  var displayText: String {
    displayLines.joined(separator: "\n")
  }

  var lineCount: Int {
    max(visualLines.count, 1)
  }

  init(
    visualLines: [DashboardReviewFileDiffWrappedVisualLine],
    highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan] = []
  ) {
    self.visualLines =
      visualLines.isEmpty
      ? [
        DashboardReviewFileDiffWrappedVisualLine(
          text: "",
          leadingIndentColumns: 0,
          sourceOffsets: nil
        )
      ] : visualLines
    self.highlightSpans = highlightSpans
  }

  static func unwrapped(_ text: String) -> Self {
    Self(
      visualLines: [
        DashboardReviewFileDiffWrappedVisualLine(
          text: text,
          leadingIndentColumns: 0,
          sourceOffsets: nil
        )
      ]
    )
  }
}

enum DashboardReviewFileDiffWrapLayout {
  static let minimumCharacterBudget = 12
  static let minimumContinuationContent = 8
  static let fallbackHangIndent = 2
  static let structuralFragmentCharacters: Set<Character> = [
    "\"", "'", "`", ",", ".", ":", ";", ")", "]", "}",
  ]
  static let stringFallbackBreakCharacters: Set<Character> = [
    "-", "/", "_", ".", ",", ":",
  ]
  static let protectedSpanMarkers = ["\"", "'", "`", "//", "/*", "#", "--", "<!--"]
  static let simpleCodeBreakCharacters: Set<Character> = [
    ":", ";", ")", "]", "}", "(", "[", "{", ".", "/", "\\", "=", ">", "<",
  ]

  static func layout(
    row: DashboardReviewFileDiffRow,
    language: HarnessCodeLanguage,
    softWrapEnabled: Bool,
    characterLimit: Int
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    guard softWrapEnabled else { return .unwrapped(row.text) }
    let resolvedCharacterLimit = max(characterLimit, minimumCharacterBudget)
    switch row.kind {
    case .addition, .context, .deletion:
      return wrapCodeRow(
        row.text,
        language: language,
        characterLimit: resolvedCharacterLimit
      )
    case .contextGap, .hunk, .metadata:
      if row.text.count <= resolvedCharacterLimit {
        return .unwrapped(row.text)
      }
      return wrapPlainText(row.text, characterLimit: resolvedCharacterLimit)
    }
  }

  static func wrapCodeRow(
    _ text: String,
    language: HarnessCodeLanguage,
    characterLimit: Int
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    let positions = characterPositions(in: text)
    let highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan]
    let protected: Set<Int>
    let stringSpans: [Range<Int>]
    if requiresProtectedSpanAnalysis(in: text) {
      let highlights = HarnessCodeHighlighter.highlights(text, language: language)
      highlightSpans = highlightOffsetSpans(highlights: highlights, positions: positions)
      protected = protectedOffsets(highlightSpans: highlightSpans)
      stringSpans = highlightSpans.filter { $0.kind == .string }.map(\.range)
    } else {
      highlightSpans = []
      protected = []
      stringSpans = []
    }
    return wrapText(
      text,
      positions: positions,
      highlightSpans: highlightSpans,
      protectedOffsets: protected,
      characterLimit: characterLimit,
      breakpointScore: { previous, next, breakAfterOffset in
        if let stringScore = scoreProtectedStringBreakpoint(
          previous: previous,
          next: next,
          breakAfterOffset: breakAfterOffset,
          stringSpans: stringSpans,
          protectedOffsets: protected,
          characterCount: positions.count - 1
        ) {
          return stringScore
        }
        guard
          !boundaryIsProtected(
            protectedOffsets: protected,
            nextOffset: breakAfterOffset,
            characterCount: positions.count - 1
          )
        else {
          return nil
        }
        return scoreCodeBreakpoint(
          previous: previous,
          next: next,
          breakAfterOffset: breakAfterOffset,
          protectedOffsets: protected
        )
      },
      continuationIndentColumns: { breakAfterOffset, _ in
        simpleContinuationIndentColumns(in: text, breakAfterOffset: breakAfterOffset)
      }
    )
  }

  static func wrapPlainText(
    _ text: String,
    characterLimit: Int
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    let positions = characterPositions(in: text)
    return wrapText(
      text,
      positions: positions,
      highlightSpans: [],
      protectedOffsets: [],
      characterLimit: characterLimit,
      breakpointScore: { previous, next, _ in
        if previous == " " || previous == "\t" { return 40 }
        if previous == "/" || previous == "." || previous == "-" || previous == "_" { return 20 }
        if next == " " || next == "\t" { return 15 }
        return nil
      },
      continuationIndentColumns: { _, _ in 0 }
    )
  }

  static func wrapText(
    _ text: String,
    positions: [String.Index],
    highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan],
    protectedOffsets: Set<Int>,
    characterLimit: Int,
    breakpointScore: (Character, Character, Int) -> Int?,
    continuationIndentColumns: (Int, Int) -> Int
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    guard positions.count > 1 else {
      return DashboardReviewFileDiffWrappedRowLayout(
        visualLines: [
          DashboardReviewFileDiffWrappedVisualLine(
            text: text,
            leadingIndentColumns: 0,
            sourceOffsets: text.isEmpty ? nil : 0..<0
          )
        ],
        highlightSpans: highlightSpans
      )
    }

    let characterCount = positions.count - 1
    let resolvedCharacterLimit = max(characterLimit, minimumCharacterBudget)
    let columnPrefix = DashboardReviewFileDiffDisplayColumns.prefixSums(
      text: text,
      positions: positions
    )
    func columns(_ lower: Int, _ upper: Int) -> Int {
      columnPrefix[upper] - columnPrefix[lower]
    }
    // Largest offset whose column span from `start` still fits `budget`,
    // always advancing at least one character so wrapping terminates even
    // when a single wide glyph already exceeds the budget on its own.
    func offsetFitting(from start: Int, within budget: Int) -> Int {
      var offset = start
      while offset < characterCount, columns(start, offset + 1) <= budget {
        offset += 1
      }
      return max(offset, start + 1)
    }

    var visualLines: [DashboardReviewFileDiffWrappedVisualLine] = []
    visualLines.reserveCapacity(max(characterCount / resolvedCharacterLimit, 1) + 1)

    var startOffset = 0
    var currentIndentColumns = 0
    var firstLine = true

    while startOffset < characterCount {
      let availableColumns =
        firstLine
        ? resolvedCharacterLimit
        : max(resolvedCharacterLimit - currentIndentColumns, minimumContinuationContent)

      if columns(startOffset, characterCount) <= availableColumns {
        visualLines.append(
          DashboardReviewFileDiffWrappedVisualLine(
            text: String(text[positions[startOffset]..<positions[characterCount]]),
            leadingIndentColumns: firstLine ? 0 : currentIndentColumns,
            sourceOffsets: startOffset..<characterCount
          )
        )
        break
      }

      let forcedBreak = offsetFitting(from: startOffset, within: availableColumns)
      let breakAfterOffset =
        bestBreakpoint(
          in: text,
          positions: positions,
          protectedOffsets: protectedOffsets,
          startOffset: startOffset,
          limitOffset: forcedBreak,
          breakpointScore: breakpointScore
        ) ?? safeForcedBreakOffset(
          protectedOffsets: protectedOffsets,
          startOffset: startOffset,
          limitOffset: forcedBreak,
          characterCount: characterCount
        )
      guard breakAfterOffset < characterCount else {
        visualLines.append(
          DashboardReviewFileDiffWrappedVisualLine(
            text: String(text[positions[startOffset]..<positions[characterCount]]),
            leadingIndentColumns: firstLine ? 0 : currentIndentColumns,
            sourceOffsets: startOffset..<characterCount
          )
        )
        break
      }

      let emittedBreakAfterOffset = trimTrailingBreakWhitespace(
        in: text,
        positions: positions,
        startOffset: startOffset,
        breakAfterOffset: breakAfterOffset
      )
      visualLines.append(
        DashboardReviewFileDiffWrappedVisualLine(
          text: String(text[positions[startOffset]..<positions[emittedBreakAfterOffset]]),
          leadingIndentColumns: firstLine ? 0 : currentIndentColumns,
          sourceOffsets: startOffset..<emittedBreakAfterOffset
        )
      )

      // Clamp the hanging indent so indent + content can never exceed the
      // budget; a continuation always keeps room for real content.
      let rawIndent = continuationIndentColumns(breakAfterOffset, resolvedCharacterLimit)
      currentIndentColumns = max(
        0,
        min(rawIndent, resolvedCharacterLimit - minimumContinuationContent)
      )
      startOffset = skipContinuationWhitespace(
        in: text,
        positions: positions,
        from: breakAfterOffset
      )
      firstLine = false
    }

    return DashboardReviewFileDiffWrappedRowLayout(
      visualLines: visualLines,
      highlightSpans: highlightSpans
    )
  }

  struct BreakpointCandidate {
    let offset: Int
    let score: Int
    let distance: Int
    let preferBackward: Bool
  }
}
