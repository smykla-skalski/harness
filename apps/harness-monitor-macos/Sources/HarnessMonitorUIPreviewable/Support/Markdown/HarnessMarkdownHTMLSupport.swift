import Foundation

struct HTMLInlineTag: Equatable {
  let name: String
  let attributes: [String: String]
  let isClosing: Bool
  let isSelfClosing: Bool
  let end: Int

  init?(characters: [Character], start: Int) {
    guard start < characters.count, characters[start] == "<" else { return nil }
    var index = start + 1
    var closing = false
    if index < characters.count, characters[index] == "/" {
      closing = true
      index += 1
    }
    while index < characters.count, characters[index].isWhitespace {
      index += 1
    }
    let nameStart = index
    while index < characters.count, isNameCharacter(characters[index]) {
      index += 1
    }
    guard index > nameStart else { return nil }
    guard index == characters.count || isTagNameTerminator(characters[index]) else { return nil }
    let parsedName = String(characters[nameStart..<index]).lowercased()
    var attributes: [String: String] = [:]
    var quote: Character?
    var tagEnd: Int?
    while index < characters.count {
      let character = characters[index]
      if let activeQuote = quote {
        if character == activeQuote { quote = nil }
        index += 1
      } else if character == "\"" || character == "'" {
        quote = character
        index += 1
      } else if character == ">" {
        tagEnd = index
        break
      } else {
        index += 1
      }
    }
    guard let end = tagEnd else { return nil }
    if !closing {
      attributes = parseAttributes(
        characters: characters, start: nameStart + parsedName.count, end: end)
    }
    self.name = parsedName
    self.attributes = attributes
    self.isClosing = closing
    self.isSelfClosing = !closing && end > start && characters[end - 1] == "/"
    self.end = end
  }
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
