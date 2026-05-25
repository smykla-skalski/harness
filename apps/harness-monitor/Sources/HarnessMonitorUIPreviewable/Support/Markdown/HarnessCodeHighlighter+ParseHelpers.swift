extension HarnessCodeHighlighter {
  static func startsCaseInsensitive(
    _ needle: String,
    in source: String,
    at index: String.Index
  ) -> Bool {
    source[index...].range(of: needle, options: [.anchored, .caseInsensitive]) != nil
  }

  static func starts(_ needle: String, in source: String, at index: String.Index) -> Bool {
    source[index...].hasPrefix(needle)
  }

  static func nextNonWhitespace(in source: String, from index: String.Index) -> Character? {
    var candidate = index
    while candidate < source.endIndex {
      let character = source[candidate]
      if !character.isWhitespace { return character }
      source.formIndex(after: &candidate)
    }
    return nil
  }

  static func firstUnquotedColon(
    in source: String,
    range: Range<String.Index>
  ) -> String.Index? {
    var quote: Character?
    var index = range.lowerBound
    while index < range.upperBound {
      let character = source[index]
      if character == "\"" || character == "'" {
        quote = quote == nil ? character : nil
      } else if character == ":", quote == nil {
        return index
      }
      source.formIndex(after: &index)
    }
    return nil
  }

  static func isIdentifierStart(_ character: Character) -> Bool {
    character.isLetter || character == "_"
  }

  static func isIdentifierPart(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  static func isFeatureDocstringDelimiter(_ line: Substring) -> Bool {
    line.hasPrefix("\"\"\"") || line.hasPrefix("```")
  }

  static func featureStepPrefix(for line: Substring) -> String? {
    if line.hasPrefix("* ") || (line.count == 1 && line.first == "*") {
      return "*"
    }
    let lowercased = String(line).lowercased()
    for prefix in featureStepPrefixes {
      if lowercased == prefix || lowercased.hasPrefix("\(prefix) ") {
        return String(line.prefix(prefix.count))
      }
    }
    return nil
  }

  static func leadingWhitespaceEnd(
    in source: String,
    range: Range<String.Index>
  ) -> String.Index {
    var index = range.lowerBound
    while index < range.upperBound, source[index].isWhitespace {
      source.formIndex(after: &index)
    }
    return index
  }

  static func appendIgnorePattern(
    in source: String,
    range: Range<String.Index>,
    to spans: inout [HarnessCodeSpan]
  ) {
    var index = range.lowerBound
    while index < range.upperBound {
      let character = source[index]
      if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: { currentIndex, currentCharacter in
            currentIndex < range.upperBound && currentCharacter.isWhitespace
          },
          kind: .whitespace,
          to: &spans
        )
      } else if character == "#" {
        appendSpan(index..<range.upperBound, kind: .comment, to: &spans)
        index = range.upperBound
      } else if ignorePatternOperators.contains(character) {
        appendCharacter(in: source, from: &index, kind: .operatorSymbol, to: &spans)
      } else if character == "/" {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else {
        appendRun(
          in: source,
          from: &index,
          while: { currentIndex, currentCharacter in
            currentIndex < range.upperBound
              && !currentCharacter.isWhitespace
              && currentCharacter != "#"
              && !ignorePatternOperators.contains(currentCharacter)
              && currentCharacter != "/"
          },
          kind: .plain,
          to: &spans
        )
      }
    }
  }

  static func makefileDirectivePrefix(for line: Substring) -> String? {
    let lowercased = String(line).lowercased()
    for prefix in makefileKeywords
    where lowercased == prefix || lowercased.hasPrefix("\(prefix) ") {
      return String(line.prefix(prefix.count))
    }
    return nil
  }

  static func firstSeparator(
    in text: Substring,
    separators: [String]
  ) -> (Range<String.Index>, String)? {
    var bestMatch: (Range<String.Index>, String)?
    for separator in separators {
      guard let range = text.range(of: separator) else { continue }
      if let currentBestMatch = bestMatch {
        if range.lowerBound < currentBestMatch.0.lowerBound {
          bestMatch = (range, separator)
        }
      } else {
        bestMatch = (range, separator)
      }
    }
    return bestMatch
  }

  static func scalarKind(for value: Substring) -> HarnessCodeToken.Kind {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      return .plain
    }
    let lowercased = trimmed.lowercased()
    if literals.contains(lowercased) || ["on", "off", "yes", "no"].contains(lowercased) {
      return .literal
    }
    if Double(trimmed) != nil {
      return .number
    }
    if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
      || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
    {
      return .string
    }
    return .plain
  }

  static func highlightLines<State>(
    in source: String,
    initialState: State,
    body: (Range<String.Index>, inout State, inout [HarnessCodeSpan]) -> Void
  ) -> HarnessCodeHighlights {
    guard !source.isEmpty else { return .empty }

    var state = initialState
    var spans: [HarnessCodeSpan] = []
    var lineStart = source.startIndex
    while lineStart < source.endIndex {
      let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
      body(lineStart..<lineEnd, &state, &spans)
      guard lineEnd < source.endIndex else { break }
      let nextStart = source.index(after: lineEnd)
      appendSpan(lineEnd..<nextStart, kind: .whitespace, to: &spans)
      lineStart = nextStart
    }
    return buildHighlights(source: source, spans: spans)
  }

  static func appendSpan(
    _ range: Range<String.Index>,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    guard !range.isEmpty else { return }
    if let last = spans.last, last.kind == kind, last.range.upperBound == range.lowerBound {
      spans[spans.count - 1] = .init(range: last.range.lowerBound..<range.upperBound, kind: kind)
    } else {
      spans.append(.init(range: range, kind: kind))
    }
  }

  static func buildHighlights(
    source: String,
    spans: [HarnessCodeSpan]
  ) -> HarnessCodeHighlights {
    guard !source.isEmpty else { return .empty }
    guard !spans.isEmpty else {
      return HarnessCodeHighlights(
        source: source,
        spans: [.init(range: source.startIndex..<source.endIndex, kind: .plain)]
      )
    }
    return HarnessCodeHighlights(source: source, spans: spans)
  }

  static func isVueTagNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_"
  }

  static func isVueAttributeCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_"
      || character == ":" || character == "@" || character == "." || character == "#"
      || character == "[" || character == "]"
  }
}
