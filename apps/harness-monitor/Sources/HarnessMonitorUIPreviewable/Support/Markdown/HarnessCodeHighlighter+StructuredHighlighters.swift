extension HarnessCodeHighlighter {
  static func highlightShell(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    while index < source.endIndex {
      let character = source[index]
      if character == "#" {
        appendUntilNewline(in: source, from: &index, kind: .comment, to: &spans)
      } else if character == "\"" || character == "'" {
        appendQuoted(in: source, from: &index, to: &spans)
      } else if character == "$" {
        appendRun(
          in: source,
          from: &index,
          while: { isIdentifierPart($0) || $0 == "$" },
          kind: .literal,
          to: &spans
        )
      } else if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if isIdentifierStart(character) {
        appendIdentifier(in: source, from: &index, keywords: shellKeywords, to: &spans)
      } else {
        let kind: HarnessCodeToken.Kind = operators.contains(character) ? .operatorSymbol : .plain
        appendCharacter(in: source, from: &index, kind: kind, to: &spans)
      }
    }
    return buildHighlights(source: source, spans: spans)
  }

  static func highlightJSON(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    while index < source.endIndex {
      let character = source[index]
      if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if jsonPunctuation.contains(character) {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else if character == "\"" {
        let start = index
        let end = quotedEnd(in: source, start: index)
        let kind: HarnessCodeToken.Kind =
          nextNonWhitespace(in: source, from: end) == ":" ? .property : .string
        appendSpan(start..<end, kind: kind, to: &spans)
        index = end
      } else {
        appendJSONLiteral(in: source, from: &index, to: &spans)
      }
    }
    return buildHighlights(source: source, spans: spans)
  }

  static func highlightYAML(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      highlightYAMLLine(in: source, lineRange: lineRange, to: &spans)
    }
  }

  static func highlightYAMLLine(
    in source: String,
    lineRange: Range<String.Index>,
    to spans: inout [HarnessCodeSpan]
  ) {
    let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
    appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
    guard trimmedStart < lineRange.upperBound else { return }

    let trimmedRange = trimmedStart..<lineRange.upperBound
    if source[trimmedStart] == "#" {
      appendSpan(trimmedRange, kind: .comment, to: &spans)
      return
    }
    guard let colon = firstUnquotedColon(in: source, range: trimmedRange) else {
      appendSpan(trimmedRange, kind: .plain, to: &spans)
      return
    }

    appendSpan(trimmedStart..<colon, kind: .property, to: &spans)
    let colonEnd = source.index(after: colon)
    appendSpan(colon..<colonEnd, kind: .punctuation, to: &spans)
    if colonEnd < lineRange.upperBound {
      let remainder = colonEnd..<lineRange.upperBound
      appendSpan(remainder, kind: scalarKind(for: source[remainder]), to: &spans)
    }
  }

  static func highlightDiff(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let text = source[lineRange]
      let kind: HarnessCodeToken.Kind =
        text.hasPrefix("@@")
        ? .heading : text.hasPrefix("+") ? .inserted : text.hasPrefix("-") ? .deleted : .plain
      appendSpan(lineRange, kind: kind, to: &spans)
    }
  }

  static func highlightMarkdown(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      let kind: HarnessCodeToken.Kind =
        trimmedStart < lineRange.upperBound && source[trimmedStart] == "#" ? .heading : .plain
      appendSpan(lineRange, kind: kind, to: &spans)
    }
  }

  static func highlightGitignore(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      appendIgnorePattern(in: source, range: trimmedRange, to: &spans)
    }
  }

  static func highlightCodeowners(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      guard let boundary = source[trimmedRange].firstIndex(where: \.isWhitespace) else {
        appendIgnorePattern(in: source, range: trimmedRange, to: &spans)
        return
      }

      appendIgnorePattern(in: source, range: trimmedStart..<boundary, to: &spans)
      var index = boundary
      while index < lineRange.upperBound {
        let character = source[index]
        if character.isWhitespace {
          appendRun(
            in: source,
            from: &index,
            while: { currentIndex, currentCharacter in
              currentIndex < lineRange.upperBound && currentCharacter.isWhitespace
            },
            kind: .whitespace,
            to: &spans
          )
        } else if character == "#" {
          appendSpan(index..<lineRange.upperBound, kind: .comment, to: &spans)
          index = lineRange.upperBound
        } else if character == "@" {
          appendRun(
            in: source,
            from: &index,
            while: { currentIndex, currentCharacter in
              currentIndex < lineRange.upperBound
                && !currentCharacter.isWhitespace
                && currentCharacter != "#"
            },
            kind: .property,
            to: &spans
          )
        } else {
          appendRun(
            in: source,
            from: &index,
            while: { currentIndex, currentCharacter in
              currentIndex < lineRange.upperBound
                && !currentCharacter.isWhitespace
                && currentCharacter != "#"
            },
            kind: .plain,
            to: &spans
          )
        }
      }
    }
  }

  static func highlightMakefile(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      let line = source[lineRange]
      let trimmed = source[trimmedRange]
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      if line.first == "\t" {
        appendSpan(trimmedRange, kind: .plain, to: &spans)
        return
      }
      if let directive = makefileDirectivePrefix(for: trimmed) {
        let boundary = source.index(trimmedStart, offsetBy: directive.count)
        appendSpan(trimmedStart..<boundary, kind: .keyword, to: &spans)
        if boundary < lineRange.upperBound {
          appendSpan(boundary..<lineRange.upperBound, kind: .plain, to: &spans)
        }
        return
      }
      if let (range, _) = firstSeparator(in: trimmed, separators: [":=", "+=", "?=", "="]) {
        appendSpan(trimmedStart..<range.lowerBound, kind: .property, to: &spans)
        appendSpan(range, kind: .operatorSymbol, to: &spans)
        if range.upperBound < lineRange.upperBound {
          appendSpan(range.upperBound..<lineRange.upperBound, kind: .plain, to: &spans)
        }
        return
      }
      if let colon = trimmed.firstIndex(of: ":") {
        appendSpan(trimmedStart..<colon, kind: .property, to: &spans)
        let afterColon = source.index(after: colon)
        appendSpan(colon..<afterColon, kind: .punctuation, to: &spans)
        if afterColon < lineRange.upperBound {
          appendSpan(afterColon..<lineRange.upperBound, kind: .plain, to: &spans)
        }
        return
      }
      appendSpan(trimmedRange, kind: .plain, to: &spans)
    }
  }

  static func highlightConfig(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      let trimmed = source[trimmedRange]
      if source[trimmedStart] == "#" || source[trimmedStart] == ";" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        appendSpan(trimmedRange, kind: .heading, to: &spans)
        return
      }
      if let (range, _) = firstSeparator(in: trimmed, separators: ["=", ":"]) {
        appendSpan(trimmedStart..<range.lowerBound, kind: .property, to: &spans)
        appendSpan(range, kind: .punctuation, to: &spans)
        if range.upperBound < lineRange.upperBound {
          let remainder = range.upperBound..<lineRange.upperBound
          appendSpan(remainder, kind: scalarKind(for: source[remainder]), to: &spans)
        }
        return
      }
      appendSpan(trimmedRange, kind: .plain, to: &spans)
    }
  }

  static func highlightTOML(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      let trimmed = source[trimmedRange]
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        appendSpan(trimmedRange, kind: .heading, to: &spans)
        return
      }
      if let (range, _) = firstSeparator(in: trimmed, separators: ["="]) {
        appendSpan(trimmedStart..<range.lowerBound, kind: .property, to: &spans)
        appendSpan(range, kind: .punctuation, to: &spans)
        if range.upperBound < lineRange.upperBound {
          let remainder = range.upperBound..<lineRange.upperBound
          appendSpan(remainder, kind: scalarKind(for: source[remainder]), to: &spans)
        }
        return
      }
      appendSpan(trimmedRange, kind: .plain, to: &spans)
    }
  }
}
