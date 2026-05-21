import Foundation

enum HarnessMarkdownInlineImageScanner {
  static func appendImage(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline],
    references: [String: HarnessMarkdownReference]
  ) -> Bool {
    guard startsImage(in: characters, at: index),
      let labelEnd = matchingBracket(in: characters, at: index + 1)
    else { return false }

    let alt = String(characters[(index + 2)..<labelEnd])
    if appendInlineImage(
      alt: alt, labelEnd: labelEnd, in: characters, from: &index, buffer: &buffer, into: &parts)
    {
      return true
    }
    let reference = referenceLabel(after: labelEnd, label: alt, in: characters)
    guard let target = references[normalizedReference(reference.label)] else { return false }
    flush(&buffer, into: &parts)
    parts.append(
      .image(HarnessMarkdownImage(source: target.destination, alt: alt, title: target.title)))
    index = reference.end
    return true
  }

  private static func appendInlineImage(
    alt: String,
    labelEnd: Int,
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) -> Bool {
    guard labelEnd + 1 < characters.count, characters[labelEnd + 1] == "(",
      let destination = linkDestination(in: characters, afterOpeningParen: labelEnd + 1)
    else { return false }
    let parsed = destinationAndTitle(destination.raw)
    guard !parsed.destination.isEmpty else { return false }
    flush(&buffer, into: &parts)
    parts.append(
      .image(HarnessMarkdownImage(source: parsed.destination, alt: alt, title: parsed.title)))
    index = destination.end + 1
    return true
  }

  private static func startsImage(in characters: [Character], at index: Int) -> Bool {
    index + 1 < characters.count && characters[index] == "!" && characters[index + 1] == "["
  }

  private static func flush(_ buffer: inout String, into parts: inout [HarnessMarkdownInline]) {
    guard !buffer.isEmpty else { return }
    parts.append(.text(buffer))
    buffer.removeAll(keepingCapacity: true)
  }

  private static func matchingBracket(in characters: [Character], at start: Int) -> Int? {
    var index = start + 1
    var depth = 1
    while index < characters.count {
      if characters[index] == "\\" {
        index += 2
      } else if characters[index] == "[" {
        depth += 1
        index += 1
      } else if characters[index] == "]" {
        depth -= 1
        if depth == 0 { return index }
        index += 1
      } else {
        index += 1
      }
    }
    return nil
  }

  private static func linkDestination(in characters: [Character], afterOpeningParen start: Int) -> (
    raw: String, end: Int
  )? {
    var index = start + 1
    var depth = 0
    var quote: Character?
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        index += 2
      } else if character == "\"" || character == "'" {
        quote = quote == nil ? character : (quote == character ? nil : quote)
        index += 1
      } else if character == "(", quote == nil {
        depth += 1
        index += 1
      } else if character == ")", quote == nil {
        if depth == 0 { return (String(characters[(start + 1)..<index]), index) }
        depth -= 1
        index += 1
      } else {
        index += 1
      }
    }
    return nil
  }

  private static func destinationAndTitle(_ raw: String) -> (destination: String, title: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
      let destination = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
      return (destination, parsedTitle(String(trimmed[trimmed.index(after: close)...])))
    }
    guard let split = trimmed.firstIndex(where: \.isWhitespace) else { return (trimmed, nil) }
    return (String(trimmed[..<split]), parsedTitle(String(trimmed[split...])))
  }

  private static func parsedTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return nil }
    if (first == "\"" && last == "\"") || (first == "'" && last == "'")
      || (first == "(" && last == ")")
    {
      return String(trimmed.dropFirst().dropLast())
    }
    return nil
  }

  private static func referenceLabel(after labelEnd: Int, label: String, in characters: [Character])
    -> (label: String, end: Int)
  {
    guard labelEnd + 1 < characters.count, characters[labelEnd + 1] == "[" else {
      return (label, labelEnd + 1)
    }
    guard let referenceEnd = first("]", in: characters, after: labelEnd + 2) else {
      return (label, labelEnd + 1)
    }
    let reference = String(characters[(labelEnd + 2)..<referenceEnd])
    return (reference.isEmpty ? label : reference, referenceEnd + 1)
  }

  private static func normalizedReference(_ label: String) -> String {
    label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func first(_ character: Character, in characters: [Character], after start: Int)
    -> Int?
  {
    var index = start
    while index < characters.count {
      if characters[index] == character { return index }
      index += 1
    }
    return nil
  }
}
