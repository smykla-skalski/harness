import Foundation

public enum SearchHighlightField: String, Hashable, Sendable {
  case title
  case subtitle
  case trailing
}

/// Inclusive UTF-16 offsets that mirror `FuseRange`.
public struct SearchHighlightRange: Hashable, Sendable {
  public let start: Int
  public let end: Int

  public init(start: Int, end: Int) {
    self.start = start
    self.end = end
  }

  public func stringRange(in text: String) -> Range<String.Index>? {
    guard start >= 0, end >= start else { return nil }
    guard
      let lowerUTF16 = text.utf16.index(
        text.utf16.startIndex,
        offsetBy: start,
        limitedBy: text.utf16.endIndex
      ),
      let upperUTF16 = text.utf16.index(
        text.utf16.startIndex,
        offsetBy: end + 1,
        limitedBy: text.utf16.endIndex
      ),
      let lower = String.Index(lowerUTF16, within: text),
      let upper = String.Index(upperUTF16, within: text)
    else {
      return nil
    }
    return lower..<upper
  }
}

public struct SearchHighlights: Hashable, Sendable {
  public static let empty = Self()

  public let title: [SearchHighlightRange]
  public let subtitle: [SearchHighlightRange]
  public let trailing: [SearchHighlightRange]

  public init(
    title: [SearchHighlightRange] = [],
    subtitle: [SearchHighlightRange] = [],
    trailing: [SearchHighlightRange] = []
  ) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
  }

  public func ranges(for field: SearchHighlightField) -> [SearchHighlightRange] {
    switch field {
    case .title:
      title
    case .subtitle:
      subtitle
    case .trailing:
      trailing
    }
  }
}
