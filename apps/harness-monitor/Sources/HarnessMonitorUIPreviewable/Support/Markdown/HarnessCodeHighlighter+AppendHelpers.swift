extension HarnessCodeHighlighter {
  static func appendRun(
    in source: String,
    from index: inout String.Index,
    while predicate: (Character) -> Bool,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    appendRun(
      in: source,
      from: &index,
      while: { _, character in predicate(character) },
      kind: kind,
      to: &spans
    )
  }

  static func appendRun(
    in source: String,
    from index: inout String.Index,
    while predicate: (String.Index, Character) -> Bool,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < source.endIndex, predicate(index, source[index]) {
      source.formIndex(after: &index)
    }
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  static func appendCharacter(
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    source.formIndex(after: &index)
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  static func appendUntilNewline(
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    appendRun(in: source, from: &index, while: { $0 != "\n" }, kind: kind, to: &spans)
  }

  static func appendBlockComment(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    index = source.index(index, offsetBy: 2)
    if let closingRange = source[index...].range(of: "*/") {
      index = closingRange.upperBound
    } else {
      index = source.endIndex
    }
    appendSpan(start..<index, kind: .comment, to: &spans)
  }

  static func appendQuoted(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    appendQuoted(
      in: source,
      from: &index,
      delimiter: QuotedDelimiter(quote: source[index], supportsEscapes: true),
      to: &spans
    )
  }

  static func appendQuoted(
    in source: String,
    from index: inout String.Index,
    delimiter: QuotedDelimiter,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    let end = quotedEnd(in: source, start: index, delimiter: delimiter)
    appendSpan(start..<end, kind: .string, to: &spans)
    index = end
  }

  static func appendIdentifier(
    in source: String,
    from index: inout String.Index,
    keywords: Set<String>,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    source.formIndex(after: &index)
    while index < source.endIndex, isIdentifierPart(source[index]) {
      source.formIndex(after: &index)
    }
    let text = String(source[start..<index])
    let kind: HarnessCodeToken.Kind =
      keywords.contains(text)
      ? .keyword
      : literals.contains(text) ? .literal : text.first?.isUppercase == true ? .type : .plain
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  static func appendJSONLiteral(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < source.endIndex,
      !source[index].isWhitespace,
      !jsonPunctuation.contains(source[index])
    {
      source.formIndex(after: &index)
    }
    let text = String(source[start..<index])
    let kind: HarnessCodeToken.Kind = literals.contains(text) ? .literal : .number
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  static func appendThroughSequence(
    _ needle: String,
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    if let range = source[index...].range(of: needle) {
      index = range.upperBound
    } else {
      index = source.endIndex
    }
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  static func appendSequence(
    _ needle: String,
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    guard let range = source[index...].range(of: needle, options: [.anchored]) else { return }
    index = range.upperBound
    appendSpan(range, kind: kind, to: &spans)
  }

  static func appendUntilCaseInsensitive(
    _ needle: String,
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    if let range = source[index...].range(of: needle, options: [.caseInsensitive]) {
      index = range.lowerBound
    } else {
      index = source.endIndex
    }
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  static func quotedEnd(in source: String, start: String.Index) -> String.Index {
    quotedEnd(
      in: source,
      start: start,
      delimiter: QuotedDelimiter(quote: source[start], supportsEscapes: true)
    )
  }

  static func quotedEnd(
    in source: String,
    start: String.Index,
    delimiter: QuotedDelimiter
  ) -> String.Index {
    var index = source.index(after: start)
    var escaped = false
    while index < source.endIndex {
      let character = source[index]
      source.formIndex(after: &index)
      if character == delimiter.closing, !escaped {
        return index
      }
      if delimiter.supportsEscapes {
        if character == "\\" {
          escaped.toggle()
        } else {
          escaped = false
        }
      }
    }
    return source.endIndex
  }

  static func stringDelimiter(
    matching character: Character,
    in delimiters: [QuotedDelimiter]
  ) -> QuotedDelimiter? {
    delimiters.first { $0.opening == character }
  }
}
