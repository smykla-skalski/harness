import Foundation
import HarnessMonitorKit
import SwiftUI

/// Shared decoder used by `HarnessMonitorJSONPresentation.formatted(rawJSON:)`.
/// The presentation is built on every parent body re-evaluation, so a per-call
/// `JSONDecoder()` would show up as steady-state allocations in Instruments.
private let jsonPresentationDecoder = JSONDecoder()

struct HarnessMonitorJSONCodeBlock: View {
  enum Chrome {
    case card
    case plain
  }

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private let chrome: Chrome
  private let presentation: HarnessMonitorJSONPresentation
  private let wrapLongLines: Bool

  init(
    presentation: HarnessMonitorJSONPresentation,
    chrome: Chrome = .card,
    wrapLongLines: Bool = false
  ) {
    self.chrome = chrome
    self.presentation = presentation
    self.wrapLongLines = wrapLongLines
  }

  init(
    rawJSON: String,
    chrome: Chrome = .card,
    wrapLongLines: Bool = false
  ) {
    self.chrome = chrome
    self.wrapLongLines = wrapLongLines
    presentation = .formatted(rawJSON: rawJSON)
  }

  init(
    jsonValue: JSONValue,
    chrome: Chrome = .card,
    wrapLongLines: Bool = false
  ) {
    self.chrome = chrome
    self.wrapLongLines = wrapLongLines
    presentation = .formatted(jsonValue: jsonValue)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let errorMessage = presentation.errorMessage {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXS) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(HarnessMonitorTheme.danger)
            .accessibilityHidden(true)
          Text(errorMessage)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
      }

      codeContent
    }
    .padding(contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      backgroundShape.fill(HarnessMonitorTheme.ink.opacity(backgroundOpacity))
    }
    .overlay {
      backgroundShape.stroke(
        HarnessMonitorTheme.controlBorder.opacity(borderOpacity),
        lineWidth: borderLineWidth
      )
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var codeContent: some View {
    if wrapLongLines {
      Text(presentation.attributedText)
        .scaledFont(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 0) {
          Text(presentation.attributedText)
            .scaledFont(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var contentPadding: CGFloat {
    switch chrome {
    case .card:
      HarnessMonitorTheme.spacingSM
    case .plain:
      0
    }
  }

  private var backgroundShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
  }

  private var backgroundOpacity: Double {
    switch chrome {
    case .card:
      colorSchemeContrast == .increased ? 0.1 : 0.05
    case .plain:
      0
    }
  }

  private var borderOpacity: Double {
    switch chrome {
    case .card:
      colorSchemeContrast == .increased ? 0.9 : 0.6
    case .plain:
      0
    }
  }

  private var borderLineWidth: CGFloat {
    switch chrome {
    case .card:
      colorSchemeContrast == .increased ? 2 : 1
    case .plain:
      0
    }
  }
}

struct HarnessMonitorJSONPresentation: Equatable, Sendable {
  let displayText: String
  let tokens: [HarnessMonitorJSONToken]
  let attributedText: AttributedString
  let errorMessage: String?

  init(
    displayText: String,
    tokens: [HarnessMonitorJSONToken],
    errorMessage: String?
  ) {
    self.displayText = displayText
    self.tokens = tokens
    attributedText = Self.makeAttributedText(from: tokens)
    self.errorMessage = errorMessage
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.displayText == rhs.displayText
      && lhs.tokens == rhs.tokens
      && lhs.errorMessage == rhs.errorMessage
  }

  private static func makeAttributedText(
    from tokens: [HarnessMonitorJSONToken]
  ) -> AttributedString {
    tokens.reduce(into: AttributedString()) { result, token in
      var fragment = AttributedString(token.text)
      fragment.foregroundColor = token.kind.color
      result += fragment
    }
  }

  static func formatted(rawJSON: String) -> Self {
    guard
      let data = rawJSON.data(using: .utf8),
      let jsonValue = try? jsonPresentationDecoder.decode(JSONValue.self, from: data)
    else {
      return Self(
        displayText: rawJSON,
        tokens: [.init(text: rawJSON, kind: .plain)],
        errorMessage: "Could not format JSON. Showing raw payload."
      )
    }

    return formatted(jsonValue: jsonValue)
  }

  static func formatted(jsonValue: JSONValue) -> Self {
    let displayText = jsonValue.prettyPrintedJSONString()
    return Self(
      displayText: displayText,
      tokens: HarnessMonitorJSONTokenizer.tokenize(displayText),
      errorMessage: nil
    )
  }
}

struct HarnessMonitorJSONToken: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case boolean
    case key
    case null
    case number
    case plain
    case punctuation
    case stringValue
    case whitespace

    fileprivate var color: Color {
      switch self {
      case .boolean:
        HarnessMonitorTheme.caution
      case .key:
        HarnessMonitorTheme.accent
      case .null, .punctuation:
        HarnessMonitorTheme.tertiaryInk
      case .number:
        HarnessMonitorTheme.warmAccent
      case .plain, .whitespace:
        HarnessMonitorTheme.secondaryInk
      case .stringValue:
        HarnessMonitorTheme.success
      }
    }
  }

  let text: String
  let kind: Kind
}

private enum HarnessMonitorJSONTokenizer {
  private static let punctuation: Set<Character> = ["{", "}", "[", "]", ":", ","]

  static func tokenize(_ displayText: String) -> [HarnessMonitorJSONToken] {
    let characters = Array(displayText)
    var index = 0
    var tokens: [HarnessMonitorJSONToken] = []

    while index < characters.count {
      let character = characters[index]
      if character.isWhitespace {
        let start = index
        while index < characters.count, characters[index].isWhitespace {
          index += 1
        }
        tokens.append(
          .init(text: String(characters[start..<index]), kind: .whitespace)
        )
        continue
      }

      if Self.punctuation.contains(character) {
        tokens.append(.init(text: String(character), kind: .punctuation))
        index += 1
        continue
      }

      if character == "\"" {
        let end = closingQuoteIndex(in: characters, start: index)
        let tokenText = String(characters[index...end])
        let kind: HarnessMonitorJSONToken.Kind =
          nextNonWhitespaceCharacter(in: characters, after: end) == ":" ? .key : .stringValue
        tokens.append(.init(text: tokenText, kind: kind))
        index = end + 1
        continue
      }

      let start = index
      while index < characters.count,
        !characters[index].isWhitespace,
        !Self.punctuation.contains(characters[index])
      {
        index += 1
      }
      let tokenText = String(characters[start..<index])
      tokens.append(.init(text: tokenText, kind: classifyLiteral(tokenText)))
    }

    return tokens
  }

  private static func closingQuoteIndex(in characters: [Character], start: Int) -> Int {
    var index = start + 1
    var isEscaped = false

    while index < characters.count {
      let character = characters[index]
      if character == "\"", !isEscaped {
        return index
      }
      if character == "\\", !isEscaped {
        isEscaped = true
      } else {
        isEscaped = false
      }
      index += 1
    }

    return characters.index(before: characters.endIndex)
  }

  private static func nextNonWhitespaceCharacter(
    in characters: [Character],
    after index: Int
  ) -> Character? {
    var candidate = index + 1
    while candidate < characters.count {
      let character = characters[candidate]
      if !character.isWhitespace {
        return character
      }
      candidate += 1
    }
    return nil
  }

  private static func classifyLiteral(_ literal: String) -> HarnessMonitorJSONToken.Kind {
    switch literal {
    case "true", "false":
      .boolean
    case "null":
      .null
    default:
      .number
    }
  }
}

extension JSONValue {
  private static let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  func prettyPrintedJSONString() -> String {
    guard let data = try? Self.prettyEncoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return string
  }
}
