import Foundation

/// Which side of a diff a line selection targets. `right` is the new (post
/// change) file side and the default; `left` is the old file side. The raw
/// values are the `side` query token used by `harness://` deep links.
public enum ReviewDiffSide: String, Hashable, Sendable, Codable {
  case left
  case right
}

/// A contiguous, 1-based line range inside one file of a pull-request diff.
///
/// Navigation history and `harness://` deep links use it to pinpoint not just
/// the file a reviewer was looking at but the exact lines, so back/forward and
/// shared links land on the same place. `start`/`end` are normalized so
/// `start <= end` and both are at least 1.
public struct ReviewLineSelection: Hashable, Sendable, Codable {
  public let start: Int
  public let end: Int
  public let side: ReviewDiffSide

  public init(start: Int, end: Int, side: ReviewDiffSide = .right) {
    self.start = max(1, min(start, end))
    self.end = max(1, max(start, end))
    self.side = side
  }

  public init(line: Int, side: ReviewDiffSide = .right) {
    self.init(start: line, end: line, side: side)
  }

  public var isSingleLine: Bool { start == end }

  public var lineCount: Int { end - start + 1 }

  public func contains(line: Int) -> Bool {
    line >= start && line <= end
  }

  /// The `lines` query value for a `harness://` URL: "10" for a single line,
  /// "10-20" for a range.
  public var urlLinesValue: String {
    isSingleLine ? "\(start)" : "\(start)-\(end)"
  }

  /// Parse the `lines` + `side` query pair from a `harness://` deep link.
  /// Accepts "10" and "10-20"; rejects empty, non-numeric, and below-one
  /// values. An absent or unknown `side` defaults to the right (new) side.
  public static func parse(
    linesQuery: String?,
    sideQuery: String?
  ) -> ReviewLineSelection? {
    guard let linesQuery, !linesQuery.isEmpty else { return nil }
    let side = sideQuery.flatMap(ReviewDiffSide.init(rawValue:)) ?? .right
    let parts = linesQuery.split(
      separator: "-",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    switch parts.count {
    case 1:
      guard let value = Int(parts[0]), value >= 1 else { return nil }
      return ReviewLineSelection(line: value, side: side)
    case 2:
      guard let lower = Int(parts[0]), let upper = Int(parts[1]),
        lower >= 1, upper >= 1
      else { return nil }
      return ReviewLineSelection(start: lower, end: upper, side: side)
    default:
      return nil
    }
  }
}
