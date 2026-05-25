import Foundation

struct DashboardReviewFileDiffWrappedRowLayout: Equatable {
  let displayText: String
  let lineCount: Int

  var displayLines: [String] {
    if displayText.isEmpty {
      return [""]
    }
    return displayText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  init(displayText: String, lineCount: Int) {
    self.displayText = displayText
    self.lineCount = max(lineCount, 1)
  }

  static func unwrapped(_ text: String) -> Self {
    Self(displayText: text, lineCount: 1)
  }
}

enum DashboardReviewFileDiffWrapLayout {
  private static let minimumCharacterBudget = 12
  private static let minimumContinuationContent = 8
  private static let fallbackHangIndent = 2
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
    guard row.text.count > resolvedCharacterLimit else {
      return .unwrapped(row.text)
    }
    switch row.kind {
    case .addition, .context, .deletion:
      return wrapCodeRow(
        row.text,
        language: language,
        characterLimit: resolvedCharacterLimit
      )
    case .contextGap, .hunk, .metadata:
      return wrapPlainText(row.text, characterLimit: resolvedCharacterLimit)
    }
  }

  private static func wrapCodeRow(
    _ text: String,
    language: HarnessCodeLanguage,
    characterLimit: Int
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    let positions = characterPositions(in: text)
    let protected: Set<Int>
    if requiresProtectedSpanAnalysis(in: text) {
      let highlights = HarnessCodeHighlighter.highlights(text, language: language)
      protected = protectedOffsets(highlights: highlights, positions: positions)
    } else {
      protected = []
    }
    return wrapText(
      text,
      positions: positions,
      protectedOffsets: protected,
      characterLimit: characterLimit,
      breakpointScore: { previous, next, breakAfterOffset in
        guard !boundaryIsProtected(
          protectedOffsets: protected,
          nextOffset: breakAfterOffset,
          characterCount: positions.count - 1
        ) else {
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
    protectedOffsets: Set<Int>,
    characterLimit: Int,
    breakpointScore: (Character, Character, Int) -> Int?,
    continuationIndentColumns: (Int, Int) -> Int
  ) -> DashboardReviewFileDiffWrappedRowLayout {
    guard positions.count > 1 else {
      return DashboardReviewFileDiffWrappedRowLayout(displayText: text, lineCount: 1)
    }

    let characterCount = positions.count - 1
    let resolvedCharacterLimit = max(characterLimit, minimumCharacterBudget)
    var output = String()
    output.reserveCapacity(text.count + max(characterCount / resolvedCharacterLimit, 1) * 4)

    var lineCount = 1
    var startOffset = 0
    var currentIndentColumns = 0
    var firstLine = true

    while startOffset < characterCount {
      let availableCharacters =
        firstLine
        ? resolvedCharacterLimit
        : max(resolvedCharacterLimit - currentIndentColumns, minimumContinuationContent)

      guard startOffset + availableCharacters < characterCount else {
        if !firstLine {
          output.append(String(repeating: " ", count: currentIndentColumns))
        }
        output.append(contentsOf: text[positions[startOffset]..<positions[characterCount]])
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
        ) ?? forcedBreak
      let emittedBreakAfterOffset = trimTrailingBreakWhitespace(
        in: text,
        positions: positions,
        startOffset: startOffset,
        breakAfterOffset: breakAfterOffset
      )

      if !firstLine {
        output.append(String(repeating: " ", count: currentIndentColumns))
      }
      output.append(contentsOf: text[positions[startOffset]..<positions[emittedBreakAfterOffset]])
      output.append("\n")
      lineCount += 1

      currentIndentColumns = continuationIndentColumns(breakAfterOffset, resolvedCharacterLimit)
      startOffset = skipContinuationWhitespace(
        in: text,
        positions: positions,
        from: breakAfterOffset
      )
      firstLine = false
    }

    return DashboardReviewFileDiffWrappedRowLayout(displayText: output, lineCount: lineCount)
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
    var bestOffset: Int?
    var bestScore = Int.min
    let characterCount = positions.count - 1
    for offset in stride(from: limitOffset, through: startOffset + 1, by: -1) {
      guard offset < characterCount else { continue }
      let previous = text[positions[offset - 1]]
      let next = text[positions[offset]]
      guard let score = breakpointScore(previous, next, offset) else { continue }
      if score >= 100 {
        return offset
      }
      if score > bestScore {
        bestScore = score
        bestOffset = offset
      }
    }
    return bestOffset
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
    if previous.isWhitespace { return 80 }
    if previous == "-" && next == ">" { return 70 }
    if simpleCodeBreakCharacters.contains(previous) { return 60 }
    return nil
  }

  private static func simpleContinuationIndentColumns(
    in text: String,
    breakAfterOffset _: Int
  ) -> Int {
    leadingIndentColumns(in: text) + fallbackHangIndent
  }

  private static func leadingIndentColumns(in text: String) -> Int {
    var count = 0
    for character in text {
      if character == " " || character == "\t" {
        count += 1
      } else {
        break
      }
    }
    return count
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
      if character == " " || character == "\t" {
        nextOffset += 1
      } else {
        break
      }
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
    highlights: HarnessCodeHighlights,
    positions: [String.Index]
  ) -> Set<Int> {
    guard positions.count > 1 else { return [] }
    var offsets = Set<Int>()
    var spanIndex = 0
    for offset in 0..<(positions.count - 1) {
      let characterIndex = positions[offset]
      while spanIndex < highlights.spans.count,
        highlights.spans[spanIndex].range.upperBound <= characterIndex
      {
        spanIndex += 1
      }
      guard spanIndex < highlights.spans.count else { break }
      let span = highlights.spans[spanIndex]
      if span.range.contains(characterIndex),
        (span.kind == .comment || span.kind == .string)
      {
        offsets.insert(offset)
      }
    }
    return offsets
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
