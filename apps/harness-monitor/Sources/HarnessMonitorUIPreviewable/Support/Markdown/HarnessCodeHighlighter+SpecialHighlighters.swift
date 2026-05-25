extension HarnessCodeHighlighter {
  static func highlightTemplate(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    while index < source.endIndex {
      if starts("{{/*", in: source, at: index) {
        appendThroughSequence("*/}}", in: source, from: &index, kind: .comment, to: &spans)
      } else if starts("{{!", in: source, at: index) {
        appendThroughSequence("}}", in: source, from: &index, kind: .comment, to: &spans)
      } else if starts("{{", in: source, at: index) {
        appendThroughSequence("}}", in: source, from: &index, kind: .literal, to: &spans)
      } else if source[index].isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else {
        appendTemplateText(in: source, from: &index, to: &spans)
      }
    }
    return buildHighlights(source: source, spans: spans)
  }

  static func highlightFeature(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: false) { lineRange, inDocstring, spans in
      highlightFeatureLine(in: source, lineRange: lineRange, inDocstring: &inDocstring, to: &spans)
    }
  }

  static func highlightFeatureLine(
    in source: String,
    lineRange: Range<String.Index>,
    inDocstring: inout Bool,
    to spans: inout [HarnessCodeSpan]
  ) {
    let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
    appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
    guard trimmedStart < lineRange.upperBound else { return }

    let trimmedRange = trimmedStart..<lineRange.upperBound
    let trimmed = source[trimmedRange]
    if isFeatureDocstringDelimiter(trimmed) {
      inDocstring.toggle()
      appendSpan(trimmedRange, kind: .string, to: &spans)
      return
    }
    if inDocstring {
      appendSpan(trimmedRange, kind: .string, to: &spans)
      return
    }

    let lowercased = String(trimmed).lowercased()
    if lowercased.hasPrefix("#") {
      appendSpan(trimmedRange, kind: .comment, to: &spans)
      return
    }
    if lowercased.hasPrefix("@") {
      highlightFeatureTags(in: source, range: trimmedRange, to: &spans)
      return
    }
    if let prefix = featureSectionPrefixes.first(where: { lowercased.hasPrefix($0) }) {
      let boundary = source.index(trimmedStart, offsetBy: prefix.count)
      appendSpan(trimmedStart..<boundary, kind: .heading, to: &spans)
      if boundary < lineRange.upperBound {
        appendSpan(boundary..<lineRange.upperBound, kind: .plain, to: &spans)
      }
      return
    }
    if let stepPrefix = featureStepPrefix(for: trimmed) {
      let boundary = source.index(trimmedStart, offsetBy: stepPrefix.count)
      appendSpan(trimmedStart..<boundary, kind: .keyword, to: &spans)
      if boundary < lineRange.upperBound {
        appendSpan(boundary..<lineRange.upperBound, kind: .plain, to: &spans)
      }
      return
    }
    if source[trimmedStart] == "|" {
      highlightFeatureTable(in: source, range: trimmedRange, to: &spans)
      return
    }
    appendSpan(trimmedRange, kind: .plain, to: &spans)
  }

  static func highlightFeatureTags(
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
      } else if character == "@" {
        appendRun(
          in: source,
          from: &index,
          while: { currentIndex, currentCharacter in
            currentIndex < range.upperBound
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
            currentIndex < range.upperBound
              && !currentCharacter.isWhitespace
              && currentCharacter != "#"
          },
          kind: .plain,
          to: &spans
        )
      }
    }
  }

  static func highlightFeatureTable(
    in source: String,
    range: Range<String.Index>,
    to spans: inout [HarnessCodeSpan]
  ) {
    var index = range.lowerBound
    while index < range.upperBound {
      let character = source[index]
      if character == "|" {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: { currentIndex, currentCharacter in
            currentIndex < range.upperBound && currentCharacter.isWhitespace
          },
          kind: .whitespace,
          to: &spans
        )
      } else {
        appendRun(
          in: source,
          from: &index,
          while: { currentIndex, currentCharacter in
            currentIndex < range.upperBound
              && !currentCharacter.isWhitespace
              && currentCharacter != "|"
          },
          kind: .plain,
          to: &spans
        )
      }
    }
  }

  static func highlightVue(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    var rawSection: VueRawSection?

    while index < source.endIndex {
      if let currentRawSection = rawSection {
        if startsCaseInsensitive(currentRawSection.closingTag, in: source, at: index) {
          appendVueTag(in: source, from: &index, to: &spans, rawSection: &rawSection)
        } else {
          appendUntilCaseInsensitive(
            currentRawSection.closingTag,
            in: source,
            from: &index,
            kind: .plain,
            to: &spans
          )
        }
      } else if starts("<!--", in: source, at: index) {
        appendThroughSequence("-->", in: source, from: &index, kind: .comment, to: &spans)
      } else if starts("{{", in: source, at: index) {
        appendThroughSequence("}}", in: source, from: &index, kind: .literal, to: &spans)
      } else if source[index] == "<" {
        appendVueTag(in: source, from: &index, to: &spans, rawSection: &rawSection)
      } else if source[index].isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else {
        appendVueText(in: source, from: &index, to: &spans)
      }
    }

    return buildHighlights(source: source, spans: spans)
  }

  static func appendVueTag(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan],
    rawSection: inout VueRawSection?
  ) {
    guard index < source.endIndex, source[index] == "<" else { return }
    appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
    let tag = VueTagDescriptor(
      isClosing: consumeVueClosingTagMarker(in: source, from: &index, to: &spans),
      name: appendVueTagName(in: source, from: &index, to: &spans)
    )

    while index < source.endIndex {
      if finishVueTagIfNeeded(
        in: source,
        from: &index,
        to: &spans,
        rawSection: &rawSection,
        tag: tag
      ) {
        return
      }
      appendVueTagAttributeToken(in: source, from: &index, to: &spans)
    }
  }

  static func consumeVueClosingTagMarker(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) -> Bool {
    guard index < source.endIndex, source[index] == "/" else { return false }
    appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
    return true
  }

  static func appendVueTagName(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) -> String {
    let tagStart = index
    while index < source.endIndex, isVueTagNameCharacter(source[index]) {
      source.formIndex(after: &index)
    }
    let tagRange = tagStart..<index
    if !tagRange.isEmpty {
      appendSpan(tagRange, kind: .type, to: &spans)
    }
    return String(source[tagRange]).lowercased()
  }

  static func finishVueTagIfNeeded(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan],
    rawSection: inout VueRawSection?,
    tag: VueTagDescriptor
  ) -> Bool {
    if starts("/>", in: source, at: index) {
      appendSequence("/>", in: source, from: &index, kind: .punctuation, to: &spans)
      return true
    }
    guard source[index] == ">" else { return false }
    appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
    updateVueRawSection(for: tag, rawSection: &rawSection)
    return true
  }

  static func updateVueRawSection(
    for tag: VueTagDescriptor,
    rawSection: inout VueRawSection?
  ) {
    if !tag.isClosing {
      if tag.name == VueRawSection.script.rawValue {
        rawSection = .script
      } else if tag.name == VueRawSection.style.rawValue {
        rawSection = .style
      }
      return
    }
    if tag.name == VueRawSection.script.rawValue
      || tag.name == VueRawSection.style.rawValue
    {
      rawSection = nil
    }
  }

  static func appendVueTagAttributeToken(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    if source[index].isWhitespace {
      appendRun(
        in: source,
        from: &index,
        while: \.isWhitespace,
        kind: .whitespace,
        to: &spans
      )
      return
    }
    if source[index] == "\"" || source[index] == "'" {
      appendQuoted(in: source, from: &index, to: &spans)
      return
    }
    if source[index] == "=" {
      appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      return
    }
    appendVueAttribute(in: source, from: &index, to: &spans)
  }

  static func appendVueAttribute(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let attributeStart = index
    while index < source.endIndex, isVueAttributeCharacter(source[index]) {
      source.formIndex(after: &index)
    }
    if attributeStart == index {
      appendCharacter(in: source, from: &index, kind: .plain, to: &spans)
      return
    }
    appendSpan(attributeStart..<index, kind: .property, to: &spans)
  }

  static func appendVueText(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < source.endIndex,
      !source[index].isWhitespace,
      source[index] != "<",
      !starts("{{", in: source, at: index),
      !starts("<!--", in: source, at: index)
    {
      source.formIndex(after: &index)
    }
    appendSpan(start..<index, kind: .plain, to: &spans)
  }

  static func appendTemplateText(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < source.endIndex, !source[index].isWhitespace,
      !starts("{{", in: source, at: index)
    {
      source.formIndex(after: &index)
    }
    appendSpan(start..<index, kind: .plain, to: &spans)
  }
}
