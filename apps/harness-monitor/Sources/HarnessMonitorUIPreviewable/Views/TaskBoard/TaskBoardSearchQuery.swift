import Foundation

/// The board's text search, reduced to what matching needs.
///
/// Matching is literal. A narrowed board has to be explainable from what was
/// typed, so tolerating a typo is left to the suggestions under the field:
/// those are fuzzy, and picking one rewrites the text into something that does
/// match literally.
struct TaskBoardSearchQuery: Equatable, Sendable {
  /// As typed, minus the whitespace around it.
  let text: String
  /// Every term has to appear somewhere on the card, which is how two words
  /// narrow further instead of widening.
  private let terms: [String]

  static let none = Self("")

  var isEmpty: Bool { terms.isEmpty }

  init(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    self.text = trimmed
    terms =
      Self.normalized(trimmed)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  func matches(_ fields: TaskBoardFilterFields) -> Bool {
    guard !terms.isEmpty else {
      return true
    }
    let haystack = Self.normalized(fields.searchableText)
    return terms.allSatisfy(haystack.contains)
  }

  /// Case and accents are ignored, so `naive` still finds `naïve`.
  static func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
