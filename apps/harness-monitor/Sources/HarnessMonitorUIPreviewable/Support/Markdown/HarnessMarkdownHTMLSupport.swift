import Foundation

struct HTMLInlineTag: Equatable {
  let name: String
  let attributes: [String: String]
  let isClosing: Bool
  let isSelfClosing: Bool
  let end: Int

  init?(characters: [Character], start: Int) {
    guard let header = parseHTMLInlineTagHeader(characters: characters, start: start),
      let end = firstTagEnd(in: characters, from: header.attributesStart)
    else { return nil }
    self.name = header.name
    self.attributes =
      header.isClosing
      ? [:]
      : parseAttributes(characters: characters, start: header.attributesStart, end: end)
    self.isClosing = header.isClosing
    self.isSelfClosing = !header.isClosing && end > start && characters[end - 1] == "/"
    self.end = end
  }
}

private struct HTMLInlineTagHeader {
  let name: String
  let isClosing: Bool
  let attributesStart: Int
}

private func parseHTMLInlineTagHeader(
  characters: [Character],
  start: Int
) -> HTMLInlineTagHeader? {
  guard start < characters.count, characters[start] == "<" else { return nil }
  var index = start + 1
  let isClosing = index < characters.count && characters[index] == "/"
  if isClosing { index += 1 }
  while index < characters.count, characters[index].isWhitespace {
    index += 1
  }
  let nameStart = index
  while index < characters.count, isNameCharacter(characters[index]) {
    index += 1
  }
  guard index > nameStart else { return nil }
  guard index == characters.count || isTagNameTerminator(characters[index]) else { return nil }
  return HTMLInlineTagHeader(
    name: String(characters[nameStart..<index]).lowercased(),
    isClosing: isClosing,
    attributesStart: index
  )
}

private func firstTagEnd(in characters: [Character], from start: Int) -> Int? {
  var index = start
  var quote: Character?
  while index < characters.count {
    let character = characters[index]
    if let activeQuote = quote {
      if character == activeQuote { quote = nil }
    } else if character == "\"" || character == "'" {
      quote = character
    } else if character == ">" {
      return index
    }
    index += 1
  }
  return nil
}

func decodeEntities(_ source: String) -> String {
  var result = ""
  let characters = Array(source)
  var index = 0
  while index < characters.count {
    if characters[index] == "&",
      let semicolon = first(";", in: characters, after: index + 1),
      semicolon - index <= 12
    {
      let name = String(characters[(index + 1)..<semicolon])
      if let decoded = decodedEntity(name) {
        result.append(decoded)
        index = semicolon + 1
        continue
      }
    }
    result.append(characters[index])
    index += 1
  }
  return result
}

private func parseAttributes(characters: [Character], start: Int, end: Int) -> [String: String] {
  var attributes: [String: String] = [:]
  var index = start
  while index < end {
    while index < end, characters[index].isWhitespace || characters[index] == "/" {
      index += 1
    }
    let nameStart = index
    while index < end, isNameCharacter(characters[index]) {
      index += 1
    }
    guard index > nameStart else {
      index += 1
      continue
    }
    let name = String(characters[nameStart..<index]).lowercased()
    while index < end, characters[index].isWhitespace {
      index += 1
    }
    guard index < end, characters[index] == "=" else {
      attributes[name] = ""
      continue
    }
    index += 1
    while index < end, characters[index].isWhitespace {
      index += 1
    }
    attributes[name] = parseAttributeValue(characters: characters, index: &index, end: end)
  }
  return attributes
}

private func parseAttributeValue(characters: [Character], index: inout Int, end: Int) -> String {
  guard index < end else { return "" }
  if characters[index] == "\"" || characters[index] == "'" {
    let quote = characters[index]
    index += 1
    let valueStart = index
    while index < end, characters[index] != quote {
      index += 1
    }
    let value = String(characters[valueStart..<index])
    if index < end { index += 1 }
    return decodeEntities(value)
  }
  let valueStart = index
  while index < end, !characters[index].isWhitespace, characters[index] != "/" {
    index += 1
  }
  return decodeEntities(String(characters[valueStart..<index]))
}

private func decodedEntity(_ name: String) -> String? {
  switch name.lowercased() {
  case "amp":
    "&"
  case "apos":
    "'"
  case "gt":
    ">"
  case "lt":
    "<"
  case "nbsp":
    " "
  case "quot":
    "\""
  default:
    numericEntity(name)
  }
}

private func numericEntity(_ name: String) -> String? {
  if name.hasPrefix("#x"), let value = UInt32(name.dropFirst(2), radix: 16) {
    return UnicodeScalar(value).map(String.init)
  }
  if name.hasPrefix("#"), let value = UInt32(name.dropFirst(), radix: 10) {
    return UnicodeScalar(value).map(String.init)
  }
  return nil
}

private func isNameCharacter(_ character: Character) -> Bool {
  character.isLetter || character.isNumber || character == "-" || character == ":"
}

private func isTagNameTerminator(_ character: Character) -> Bool {
  character.isWhitespace || character == "/" || character == ">"
}

private func first(_ character: Character, in characters: [Character], after start: Int) -> Int? {
  var index = start
  while index < characters.count {
    if characters[index] == character { return index }
    index += 1
  }
  return nil
}
