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
  struct Strategy {
    let highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan]
    let protectedOffsets: Set<Int>
    let characterLimit: Int
    let breakpointScore: (Character, Character, Int) -> Int?
    let continuationIndentColumns: (Int, Int) -> Int
  }

  struct BreakpointSearchContext {
    let text: String
    let positions: [String.Index]
    let startOffset: Int
    let characterCount: Int
  }

  struct ProtectedStringContext {
    let stringSpans: [Range<Int>]
    let protectedOffsets: Set<Int>
    let characterCount: Int
  }

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
    let protectedContext: ProtectedStringContext
    if requiresProtectedSpanAnalysis(in: text) {
      let highlights = HarnessCodeHighlighter.highlights(text, language: language)
      highlightSpans = highlightOffsetSpans(highlights: highlights, positions: positions)
      let protectedOffsets = protectedOffsets(highlightSpans: highlightSpans)
      protectedContext = ProtectedStringContext(
        stringSpans: highlightSpans.filter { $0.kind == .string }.map(\.range),
        protectedOffsets: protectedOffsets,
        characterCount: positions.count - 1
      )
    } else {
      highlightSpans = []
      protectedContext = ProtectedStringContext(
        stringSpans: [],
        protectedOffsets: [],
        characterCount: positions.count - 1
      )
    }
    let strategy = Strategy(
      highlightSpans: highlightSpans,
      protectedOffsets: protectedContext.protectedOffsets,
      characterLimit: characterLimit,
      breakpointScore: { previous, next, breakAfterOffset in
        if let stringScore = scoreProtectedStringBreakpoint(
          previous: previous,
          next: next,
          breakAfterOffset: breakAfterOffset,
          protection: protectedContext
        ) {
          return stringScore
        }
        guard
          !boundaryIsProtected(
            protectedOffsets: protectedContext.protectedOffsets,
            nextOffset: breakAfterOffset,
            characterCount: protectedContext.characterCount
          )
        else {
          return nil
        }
        return scoreCodeBreakpoint(
          previous: previous,
          next: next,
          breakAfterOffset: breakAfterOffset,
          protectedOffsets: protectedContext.protectedOffsets
        )
      },
      continuationIndentColumns: { breakAfterOffset, _ in
        simpleContinuationIndentColumns(in: text, breakAfterOffset: breakAfterOffset)
      }
    )
    return wrapText(text, positions: positions, strategy: strategy)
  }

  static func wrapPlainText(
    _ text: String,
    characterLimit: Int
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    let positions = characterPositions(in: text)
    let strategy = Strategy(
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
    return wrapText(text, positions: positions, strategy: strategy)
  }

  static func wrapText(
    _ text: String,
    positions: [String.Index],
    strategy: Strategy
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    guard positions.count > 1 else {
      return emptyWrappedRowLayout(text: text, highlightSpans: strategy.highlightSpans)
    }

    let characterCount = positions.count - 1
    let resolvedCharacterLimit = max(strategy.characterLimit, minimumCharacterBudget)
    let columnPrefix = DashboardReviewFileDiffDisplayColumns.prefixSums(
      text: text,
      positions: positions
    )

    var visualLines: [DashboardReviewFileDiffWrappedVisualLine] = []
    visualLines.reserveCapacity(max(characterCount / resolvedCharacterLimit, 1) + 1)

    var startOffset = 0
    var currentIndentColumns = 0
    var firstLine = true

    while startOffset < characterCount {
      let iterationContext = makeIterationContext(
        text: text,
        positions: positions,
        resolvedCharacterLimit: resolvedCharacterLimit,
        firstLine: firstLine,
        currentIndentColumns: currentIndentColumns
      )

      if lineFitsWithinBudget(
        columnPrefix: columnPrefix,
        startOffset: startOffset,
        characterCount: characterCount,
        availableColumns: iterationContext.availableColumns
      ) {
        appendRemainingLine(
          &visualLines,
          context: iterationContext.lineContext,
          startOffset: startOffset,
          characterCount: characterCount
        )
        break
      }

      let forcedBreak = offsetFitting(
        columnPrefix: columnPrefix,
        startOffset: startOffset,
        budget: iterationContext.availableColumns,
        characterCount: characterCount
      )
      let breakAfterOffset = resolvedBreakAfterOffset(
        .init(
          text: text,
          positions: positions,
          startOffset: startOffset,
          characterCount: characterCount,
          forcedBreak: forcedBreak,
          strategy: strategy
        )
      )
      guard breakAfterOffset < characterCount else {
        appendRemainingLine(
          &visualLines,
          context: iterationContext.lineContext,
          startOffset: startOffset,
          characterCount: characterCount
        )
        break
      }

      let emittedBreakAfterOffset = trimTrailingBreakWhitespace(
        in: text,
        positions: positions,
        startOffset: startOffset,
        breakAfterOffset: breakAfterOffset
      )
      appendVisualLine(
        &visualLines,
        context: iterationContext.lineContext,
        startOffset: startOffset,
        endOffset: emittedBreakAfterOffset
      )

      // Clamp the hanging indent so indent + content can never exceed the
      // budget; a continuation always keeps room for real content.
      currentIndentColumns = resolvedContinuationIndent(
        strategy: strategy,
        breakAfterOffset: breakAfterOffset,
        resolvedCharacterLimit: resolvedCharacterLimit
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
      highlightSpans: strategy.highlightSpans
    )
  }

  static func emptyWrappedRowLayout(
    text: String,
    highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan]
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    DashboardReviewFileDiffWrappedRowLayout(
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

  static func visualLine(
    text: String,
    positions: [String.Index],
    startOffset: Int,
    endOffset: Int,
    leadingIndentColumns: Int
  ) -> DashboardReviewFileDiffWrappedVisualLine {
    DashboardReviewFileDiffWrappedVisualLine(
      text: String(text[positions[startOffset]..<positions[endOffset]]),
      leadingIndentColumns: leadingIndentColumns,
      sourceOffsets: startOffset..<endOffset
    )
  }

  static func displayColumns(
    columnPrefix: [Int],
    lower: Int,
    upper: Int
  ) -> Int {
    columnPrefix[upper] - columnPrefix[lower]
  }

  static func offsetFitting(
    columnPrefix: [Int],
    startOffset: Int,
    budget: Int,
    characterCount: Int
  ) -> Int {
    var offset = startOffset
    while offset < characterCount,
      displayColumns(columnPrefix: columnPrefix, lower: startOffset, upper: offset + 1) <= budget
    {
      offset += 1
    }
    return max(offset, startOffset + 1)
  }

  struct BreakpointCandidate {
    let offset: Int
    let score: Int
    let distance: Int
    let preferBackward: Bool
  }
}
