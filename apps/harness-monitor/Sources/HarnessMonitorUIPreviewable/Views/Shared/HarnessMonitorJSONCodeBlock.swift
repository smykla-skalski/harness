import Foundation
import HarnessMonitorKit
import SwiftUI

/// Shared decoder used by `HarnessMonitorJSONPresentation.formatted(rawJSON:)`.
private let jsonPresentationDecoder = JSONDecoder()

struct HarnessMonitorJSONCodeBlock: View {
  enum Chrome {
    case card
    case plain

    var codeBlockChrome: HarnessMonitorCodeBlock.Chrome {
      switch self {
      case .card:
        .card
      case .plain:
        .plain
      }
    }
  }

  private let chrome: Chrome
  private let presentation: HarnessMonitorJSONPresentation
  private let settings: HarnessCodeBlockRenderSettings
  private let wrapLongLines: Bool

  init(
    presentation: HarnessMonitorJSONPresentation,
    settings: HarnessCodeBlockRenderSettings = .default,
    chrome: Chrome = .card,
    wrapLongLines: Bool = false
  ) {
    self.chrome = chrome
    self.presentation = presentation
    self.settings = settings
    self.wrapLongLines = wrapLongLines
  }

  init(
    rawJSON: String,
    settings: HarnessCodeBlockRenderSettings = .default,
    chrome: Chrome = .card,
    wrapLongLines: Bool = false
  ) {
    self.chrome = chrome
    self.settings = settings
    self.wrapLongLines = wrapLongLines
    presentation = .formatted(rawJSON: rawJSON)
  }

  init(
    jsonValue: JSONValue,
    settings: HarnessCodeBlockRenderSettings = .default,
    chrome: Chrome = .card,
    wrapLongLines: Bool = false
  ) {
    self.chrome = chrome
    self.settings = settings
    self.wrapLongLines = wrapLongLines
    presentation = .formatted(jsonValue: jsonValue)
  }

  var body: some View {
    HarnessMonitorCodeBlock(
      presentation: presentation.codeBlockPresentation,
      settings: settings,
      chrome: chrome.codeBlockChrome,
      wrapLongLines: wrapLongLines
    )
  }
}

struct HarnessMonitorJSONPresentation: Equatable, Sendable {
  let displayText: String
  let highlights: HarnessCodeHighlights
  let errorMessage: String?

  var tokens: [HarnessCodeToken] { highlights.tokens }

  init(
    displayText: String,
    highlights: HarnessCodeHighlights,
    errorMessage: String?
  ) {
    self.displayText = displayText
    self.highlights = highlights
    self.errorMessage = errorMessage
  }

  var codeBlockPresentation: HarnessCodeBlockPresentation {
    HarnessCodeBlockPresentation(
      language: .json,
      highlights: highlights,
      errorMessage: errorMessage
    )
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.displayText == rhs.displayText
      && lhs.highlights == rhs.highlights
      && lhs.errorMessage == rhs.errorMessage
  }

  static func formatted(rawJSON: String) -> Self {
    guard
      let data = rawJSON.data(using: .utf8),
      let jsonValue = try? jsonPresentationDecoder.decode(JSONValue.self, from: data)
    else {
      return Self(
        displayText: rawJSON,
        highlights: HarnessCodeHighlights(
          source: rawJSON,
          spans: rawJSON.isEmpty
            ? [] : [.init(range: rawJSON.startIndex..<rawJSON.endIndex, kind: .plain)]
        ),
        errorMessage: "Could not format JSON. Showing raw payload"
      )
    }

    return formatted(jsonValue: jsonValue)
  }

  static func formatted(jsonValue: JSONValue) -> Self {
    let displayText = jsonValue.prettyPrintedJSONString()
    return Self(
      displayText: displayText,
      highlights: HarnessCodeHighlighter.highlights(displayText, language: .json),
      errorMessage: nil
    )
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
