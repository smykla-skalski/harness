import Foundation

extension DashboardReviewFileDiffWrapLayout {
  static func bestBreakpoint(
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

  static func trimTrailingBreakWhitespace(
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

  static func requiresProtectedSpanAnalysis(in text: String) -> Bool {
    for marker in protectedSpanMarkers where text.contains(marker) {
      return true
    }
    return false
  }

  static func scoreCodeBreakpoint(
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

  static func scoreProtectedStringBreakpoint(
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

  static func simpleContinuationIndentColumns(
    in text: String,
    breakAfterOffset _: Int
  ) -> Int {
    if startsWithQuotedLiteral(in: text) {
      return leadingIndentColumns(in: text)
    }
    return leadingIndentColumns(in: text) + fallbackHangIndent
  }

  static func leadingIndentColumns(in text: String) -> Int {
    var count = 0
    for character in text {
      guard character == " " || character == "\t" else { break }
      count += 1
    }
    return count
  }

  static func startsWithQuotedLiteral(in text: String) -> Bool {
    for character in text {
      if character == " " || character == "\t" {
        continue
      }
      return character == "\"" || character == "'" || character == "`"
    }
    return false
  }

  static func skipContinuationWhitespace(
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

  static func boundaryIsProtected(
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

  static func protectedOffsets(
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

  static func highlightOffsetSpans(
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

  static func safeForcedBreakOffset(
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

  static func bestBreakpointCandidate<S: Sequence>(
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

  static func preferredBreakpoint(
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

  static func isPreferred(
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

  static func fragmentHasVisibleContent(
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

  static func characterPositions(in text: String) -> [String.Index] {
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
