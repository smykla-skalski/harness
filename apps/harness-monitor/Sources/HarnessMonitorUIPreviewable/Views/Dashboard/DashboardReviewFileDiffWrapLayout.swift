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
  private static let minimumCharacterBudget = 12
  private static let minimumContinuationContent = 8
  private static let fallbackHangIndent = 2
  private static let forwardSearchSlack = 24
  private static let structuralFragmentCharacters: Set<Character> = [
    "\"", "'", "`", ",", ".", ":", ";", ")", "]", "}",
  ]
  private static let stringFallbackBreakCharacters: Set<Character> = [
    "-", "/", "_", ".", ",", ":",
  ]
  private static let protectedSpanMarkers = ["\"", "'", "`", "//", "/*", "#", "--", "<!--"]
  private static let simpleCodeBreakCharacters: Set<Character> = [
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

  private static func wrapCodeRow(
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

  private static func wrapPlainText(
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

  private static func wrapText(
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
    var visualLines: [DashboardReviewFileDiffWrappedVisualLine] = []
    visualLines.reserveCapacity(max(characterCount / resolvedCharacterLimit, 1) + 1)

    var startOffset = 0
    var currentIndentColumns = 0
    var firstLine = true

    while startOffset < characterCount {
      let availableCharacters =
        firstLine
        ? resolvedCharacterLimit
        : max(resolvedCharacterLimit - currentIndentColumns, minimumContinuationContent)

      if characterCount - startOffset <= availableCharacters + minimumContinuationContent {
        visualLines.append(
          DashboardReviewFileDiffWrappedVisualLine(
            text: String(text[positions[startOffset]..<positions[characterCount]]),
            leadingIndentColumns: firstLine ? 0 : currentIndentColumns,
            sourceOffsets: startOffset..<characterCount
          )
        )
        break
      }

      let forcedBreak = min(startOffset + availableCharacters, characterCount)
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

      currentIndentColumns = continuationIndentColumns(breakAfterOffset, resolvedCharacterLimit)
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

  private static func bestBreakpoint(
    in text: String,
    positions: [String.Index],
    protectedOffsets: Set<Int>,
    startOffset: Int,
    limitOffset: Int,
    breakpointScore: (Character, Character, Int) -> Int?
  ) -> Int? {
    guard limitOffset > startOffset + 1 else { return nil }
    let characterCount = positions.count - 1
    let backward = bestBreakpointCandidate(
      in: text,
      positions: positions,
      offsets: stride(from: limitOffset, through: startOffset + 1, by: -1),
      startOffset: startOffset,
      characterCount: characterCount,
      breakpointScore: breakpointScore,
      referenceOffset: limitOffset,
      preferBackward: true
    )
    let forwardUpperBound = min(
      characterCount - 1,
      limitOffset + max((limitOffset - startOffset) / 2, forwardSearchSlack)
    )
    let forward: BreakpointCandidate?
    if forwardUpperBound > limitOffset {
      forward = bestBreakpointCandidate(
        in: text,
        positions: positions,
        offsets: limitOffset + 1...forwardUpperBound,
        startOffset: startOffset,
        characterCount: characterCount,
        breakpointScore: breakpointScore,
        referenceOffset: limitOffset,
        preferBackward: false
      )
    } else {
      forward = nil
    }
    return preferredBreakpoint(backward: backward, forward: forward)?.offset
  }

  private static func trimTrailingBreakWhitespace(
    in text: String,
    positions: [String.Index],
    startOffset: Int,
    breakAfterOffset: Int
  ) -> Int {
    var trimmedOffset = breakAfterOffset
    while trimmedOffset > startOffset, text[positions[trimmedOffset - 1]].isWhitespace {
      trimmedOffset -= 1
    }
    return max(trimmedOffset, startOffset + 1)
  }

  private static func requiresProtectedSpanAnalysis(in text: String) -> Bool {
    for marker in protectedSpanMarkers where text.contains(marker) {
      return true
    }
    return false
  }

  private static func scoreCodeBreakpoint(
    previous: Character,
    next: Character,
    breakAfterOffset _: Int,
    protectedOffsets _: Set<Int>
  ) -> Int? {
    if previous == "," { return 100 }
    if previous == ")" && next == "." { return 90 }
    if previous.isWhitespace { return 80 }
    if previous == "-" && next == ">" { return 70 }
    if simpleCodeBreakCharacters.contains(previous) { return 60 }
    return nil
  }

  private static func scoreProtectedStringBreakpoint(
    previous: Character,
    next: Character,
    breakAfterOffset: Int,
    stringSpans: [Range<Int>],
    protectedOffsets: Set<Int>,
    characterCount: Int
  ) -> Int? {
    guard
      boundaryIsProtected(
        protectedOffsets: protectedOffsets,
        nextOffset: breakAfterOffset,
        characterCount: characterCount
      ),
      stringSpans.contains(where: { $0.contains(breakAfterOffset) || $0.contains(breakAfterOffset - 1) })
    else {
      return nil
    }
    if previous.isWhitespace { return 55 }
    if stringFallbackBreakCharacters.contains(previous) { return 48 }
    if next.isWhitespace { return 38 }
    return nil
  }

  private static func simpleContinuationIndentColumns(
    in text: String,
    breakAfterOffset _: Int
  ) -> Int {
    if startsWithQuotedLiteral(in: text) {
      return leadingIndentColumns(in: text)
    }
    return leadingIndentColumns(in: text) + fallbackHangIndent
  }

  private static func leadingIndentColumns(in text: String) -> Int {
    var count = 0
    for character in text {
      guard character == " " || character == "\t" else { break }
      count += 1
    }
    return count
  }

  private static func startsWithQuotedLiteral(in text: String) -> Bool {
    for character in text {
      if character == " " || character == "\t" {
        continue
      }
      return character == "\"" || character == "'" || character == "`"
    }
    return false
  }

  private static func skipContinuationWhitespace(
    in text: String,
    positions: [String.Index],
    from offset: Int
  ) -> Int {
    let characterCount = positions.count - 1
    var nextOffset = min(max(offset, 0), characterCount)
    while nextOffset < characterCount {
      let character = text[positions[nextOffset]]
      guard character == " " || character == "\t" else { break }
      nextOffset += 1
    }
    return nextOffset
  }

  private static func boundaryIsProtected(
    protectedOffsets: Set<Int>,
    nextOffset: Int,
    characterCount: Int
  ) -> Bool {
    let previousOffset = nextOffset - 1
    if previousOffset >= 0, protectedOffsets.contains(previousOffset) {
      return true
    }
    if nextOffset < characterCount, protectedOffsets.contains(nextOffset) {
      return true
    }
    return false
  }

  private static func protectedOffsets(
    highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan]
  ) -> Set<Int> {
    var offsets = Set<Int>()
    for span in highlightSpans where span.kind == .string {
      let lowerBound = span.range.lowerBound + 1
      let upperBound = span.range.upperBound - 1
      guard lowerBound < upperBound else { continue }
      for offset in lowerBound..<upperBound {
        offsets.insert(offset)
      }
    }
    return offsets
  }

  private static func highlightOffsetSpans(
    highlights: HarnessCodeHighlights,
    positions: [String.Index]
  ) -> [DashboardReviewFileDiffWrappedHighlightSpan] {
    guard positions.count > 1 else { return [] }
    let offsetByIndex = Dictionary(
      uniqueKeysWithValues: positions.enumerated().map { ($1, $0) }
    )
    return highlights.spans.compactMap { span in
      guard
        let lower = offsetByIndex[span.range.lowerBound],
        let upper = offsetByIndex[span.range.upperBound],
        lower < upper
      else {
        return nil
      }
      return DashboardReviewFileDiffWrappedHighlightSpan(
        range: lower..<upper,
        kind: span.kind
      )
    }
  }

  private static func safeForcedBreakOffset(
    protectedOffsets: Set<Int>,
    startOffset: Int,
    limitOffset: Int,
    characterCount: Int
  ) -> Int {
    guard boundaryIsProtected(
      protectedOffsets: protectedOffsets,
      nextOffset: limitOffset,
      characterCount: characterCount
    ) else {
      return limitOffset
    }

    var forward = limitOffset
    let forwardLimit = min(characterCount - 1, limitOffset + forwardSearchSlack)
    while forward < forwardLimit,
      boundaryIsProtected(
        protectedOffsets: protectedOffsets,
        nextOffset: forward,
        characterCount: characterCount
      )
    {
      forward += 1
    }
    if forward < characterCount,
      !boundaryIsProtected(
        protectedOffsets: protectedOffsets,
        nextOffset: forward,
        characterCount: characterCount
      )
    {
      return forward
    }

    var backward = limitOffset
    while backward > startOffset + 1,
      boundaryIsProtected(
        protectedOffsets: protectedOffsets,
        nextOffset: backward,
        characterCount: characterCount
      )
    {
      backward -= 1
    }
    if backward > startOffset + 1 {
      return backward
    }
    return min(max(limitOffset, startOffset + 1), characterCount - 1)
  }

  private struct BreakpointCandidate {
    let offset: Int
    let score: Int
    let distance: Int
    let preferBackward: Bool
  }

  private static func bestBreakpointCandidate<S: Sequence>(
    in text: String,
    positions: [String.Index],
    offsets: S,
    startOffset: Int,
    characterCount: Int,
    breakpointScore: (Character, Character, Int) -> Int?,
    referenceOffset: Int,
    preferBackward: Bool
  ) -> BreakpointCandidate? where S.Element == Int {
    var best: BreakpointCandidate?
    for offset in offsets {
      guard offset > 0, offset < characterCount else { continue }
      let previous = text[positions[offset - 1]]
      let next = text[positions[offset]]
      guard let score = breakpointScore(previous, next, offset) else { continue }
      guard
        fragmentHasVisibleContent(
          in: text,
          positions: positions,
          startOffset: startOffset,
          breakAfterOffset: offset
        )
      else { continue }
      let candidate = BreakpointCandidate(
        offset: offset,
        score: score,
        distance: abs(referenceOffset - offset),
        preferBackward: preferBackward
      )
      if isPreferred(candidate, over: best) {
        best = candidate
      }
    }
    return best
  }

  private static func preferredBreakpoint(
    backward: BreakpointCandidate?,
    forward: BreakpointCandidate?
  ) -> BreakpointCandidate? {
    switch (backward, forward) {
    case let (lhs?, rhs?):
      return isPreferred(lhs, over: rhs) ? lhs : rhs
    case let (lhs?, nil):
      return lhs
    case let (nil, rhs?):
      return rhs
    case (nil, nil):
      return nil
    }
  }

  private static func isPreferred(
    _ candidate: BreakpointCandidate,
    over current: BreakpointCandidate?
  ) -> Bool {
    guard let current else { return true }
    if candidate.score != current.score {
      return candidate.score > current.score
    }
    if candidate.distance != current.distance {
      return candidate.distance < current.distance
    }
    if candidate.preferBackward != current.preferBackward {
      return candidate.preferBackward
    }
    return candidate.offset < current.offset
  }

  private static func fragmentHasVisibleContent(
    in text: String,
    positions: [String.Index],
    startOffset: Int,
    breakAfterOffset: Int
  ) -> Bool {
    var sawVisible = false
    var sawNonStructural = false
    for offset in startOffset..<breakAfterOffset {
      let character = text[positions[offset]]
      if character.isWhitespace {
        continue
      }
      sawVisible = true
      if !structuralFragmentCharacters.contains(character) {
        sawNonStructural = true
        break
      }
    }
    guard sawVisible else { return false }
    return sawNonStructural
  }

  private static func characterPositions(in text: String) -> [String.Index] {
    var positions: [String.Index] = [text.startIndex]
    positions.reserveCapacity(text.count + 1)
    var index = text.startIndex
    while index < text.endIndex {
      index = text.index(after: index)
      positions.append(index)
    }
    return positions
  }
}
