import Foundation
import HarnessMonitorKit

struct DashboardReviewFileDiffDocument: Equatable {
  let path: String
  let language: HarnessReviewFileLanguage
  let rows: [DashboardReviewFileDiffRow]
  let truncated: Bool
  let headRefOid: String
  let longestCodeCharacterCount: Int

  init(patch: ReviewFilePatch, language: HarnessReviewFileLanguage) {
    self.path = patch.path
    self.language = language
    self.headRefOid = patch.headRefOid
    let lineCount = Self.estimatedLineCount(in: patch.patch)
    let interval = ReviewFilesPerf.beginDiffParse(path: patch.path, lineCount: lineCount)
    let parsed = Self.parseRows(from: patch.patch, estimatedLineCount: lineCount)
    self.rows = parsed.rows
    self.longestCodeCharacterCount = parsed.longestCodeCharacterCount
    ReviewFilesPerf.end(interval)
    self.truncated = patch.truncated
  }

  var isEmpty: Bool { rows.isEmpty }

  private static func parseRows(
    from patch: String,
    estimatedLineCount: Int
  ) -> (rows: [DashboardReviewFileDiffRow], longestCodeCharacterCount: Int) {
    guard !patch.isEmpty else { return ([], 0) }
    var rows: [DashboardReviewFileDiffRow] = []
    rows.reserveCapacity(estimatedLineCount)
    var longestCodeCharacterCount = 0
    var oldLine = 0
    var newLine = 0
    var hasSeenHunk = false
    var diffPosition = 1
    func appendRow(_ row: DashboardReviewFileDiffRow) {
      longestCodeCharacterCount = max(longestCodeCharacterCount, row.text.count)
      rows.append(row)
    }
    forEachPatchLine(in: patch) { rawLine in
      if let hunk = parseHunkHeader(rawLine) {
        let rowCountBeforeGap = rows.count
        appendContextGapIfNeeded(
          rows: &rows,
          position: .init(
            oldLine: oldLine,
            newLine: newLine,
            nextOldStart: hunk.oldStart,
            nextNewStart: hunk.newStart,
            hasSeenHunk: hasSeenHunk
          )
        )
        if rows.count > rowCountBeforeGap, let gapRow = rows.last {
          longestCodeCharacterCount = max(longestCodeCharacterCount, gapRow.text.count)
        }
        oldLine = hunk.oldStart
        newLine = hunk.newStart
        hasSeenHunk = true
        appendRow(
          row(
            rows: rows,
            kind: .hunk,
            text: String(rawLine),
            diffPosition: diffPosition
          )
        )
      } else if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
        appendRow(
          row(
            rows: rows,
            kind: hasSeenHunk ? .addition : .metadata,
            lines: .init(old: nil, new: hasSeenHunk ? normalizedLine(newLine) : nil),
            text: sourceLineText(rawLine, hasSeenHunk: hasSeenHunk),
            diffPosition: hasSeenHunk ? diffPosition : nil
          )
        )
        if hasSeenHunk {
          newLine += 1
          diffPosition += 1
        }
      } else if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
        appendRow(
          row(
            rows: rows,
            kind: hasSeenHunk ? .deletion : .metadata,
            lines: .init(old: hasSeenHunk ? normalizedLine(oldLine) : nil, new: nil),
            text: sourceLineText(rawLine, hasSeenHunk: hasSeenHunk),
            diffPosition: hasSeenHunk ? diffPosition : nil
          )
        )
        if hasSeenHunk {
          oldLine += 1
          diffPosition += 1
        }
      } else if shouldTreatAsMetadata(rawLine, hasSeenHunk: hasSeenHunk) {
        appendRow(row(rows: rows, kind: .metadata, text: String(rawLine)))
      } else {
        appendRow(
          row(
            rows: rows,
            kind: hasSeenHunk ? .context : .metadata,
            lines: .init(
              old: hasSeenHunk ? normalizedLine(oldLine) : nil,
              new: hasSeenHunk ? normalizedLine(newLine) : nil
            ),
            text: contextLineText(rawLine),
            diffPosition: hasSeenHunk ? diffPosition : nil
          )
        )
        if hasSeenHunk {
          oldLine += 1
          newLine += 1
          diffPosition += 1
        }
      }
    }
    return (rows, longestCodeCharacterCount)
  }

  private static func estimatedLineCount(in patch: String) -> Int {
    guard !patch.isEmpty else { return 0 }
    var count = 1
    for character in patch where character == "\n" {
      count += 1
    }
    return patch.hasSuffix("\n") ? count - 1 : count
  }

  private static func forEachPatchLine(
    in patch: String,
    _ body: (Substring) -> Void
  ) {
    var lineStart = patch.startIndex
    while lineStart < patch.endIndex {
      let lineEnd = patch[lineStart...].firstIndex(of: "\n") ?? patch.endIndex
      body(patch[lineStart..<lineEnd])
      guard lineEnd < patch.endIndex else { break }
      let nextLineStart = patch.index(after: lineEnd)
      guard nextLineStart < patch.endIndex else { break }
      lineStart = nextLineStart
    }
  }

  private static func row(
    rows: [DashboardReviewFileDiffRow],
    kind: DashboardReviewFileDiffRow.Kind,
    lines: LineNumbers = .none,
    text: String,
    diffPosition: Int? = nil
  ) -> DashboardReviewFileDiffRow {
    DashboardReviewFileDiffRow(
      id: rows.count,
      kind: kind,
      oldLine: lines.old,
      newLine: lines.new,
      diffPosition: diffPosition,
      text: text,
      contextGap: nil
    )
  }

  private static func contextGapRow(
    rows: [DashboardReviewFileDiffRow],
    gap: DashboardReviewFileContextGap
  ) -> DashboardReviewFileDiffRow {
    DashboardReviewFileDiffRow(
      id: rows.count,
      kind: .contextGap,
      oldLine: nil,
      newLine: nil,
      diffPosition: nil,
      text: gap.summary,
      contextGap: gap
    )
  }

  private static func appendContextGapIfNeeded(
    rows: inout [DashboardReviewFileDiffRow],
    position: HunkPosition
  ) {
    let oldHidden = hiddenLineCount(
      currentLine: position.hasSeenHunk ? position.oldLine : 1,
      nextStart: position.nextOldStart
    )
    let newHidden = hiddenLineCount(
      currentLine: position.hasSeenHunk ? position.newLine : 1,
      nextStart: position.nextNewStart
    )
    guard oldHidden > 0 || newHidden > 0 else { return }
    let gap = DashboardReviewFileContextGap(
      oldStart: normalizedLine(position.hasSeenHunk ? position.oldLine : 1),
      newStart: normalizedLine(position.hasSeenHunk ? position.newLine : 1),
      oldHiddenCount: oldHidden,
      newHiddenCount: newHidden
    )
    rows.append(contextGapRow(rows: rows, gap: gap))
  }

  private static func hiddenLineCount(currentLine: Int, nextStart: Int) -> Int {
    guard nextStart > 0, currentLine > 0 else { return 0 }
    return max(nextStart - currentLine, 0)
  }

  private static func normalizedLine(_ value: Int) -> Int? {
    value > 0 ? value : nil
  }

  private static func shouldTreatAsMetadata(_ line: Substring, hasSeenHunk: Bool) -> Bool {
    if !hasSeenHunk { return true }
    return line.hasPrefix("\\ No newline")
      || line.hasPrefix("diff --git ")
      || line.hasPrefix("index ")
      || line.hasPrefix("new file mode ")
      || line.hasPrefix("deleted file mode ")
      || line.hasPrefix("old mode ")
      || line.hasPrefix("new mode ")
      || line.hasPrefix("similarity index ")
      || line.hasPrefix("dissimilarity index ")
      || line.hasPrefix("rename from ")
      || line.hasPrefix("rename to ")
      || line.hasPrefix("copy from ")
      || line.hasPrefix("copy to ")
      || line.hasPrefix("Binary files ")
      || line.hasPrefix("--- ")
      || line.hasPrefix("+++ ")
  }

  private static func sourceLineText(_ line: Substring, hasSeenHunk: Bool) -> String {
    hasSeenHunk ? String(line.dropFirst()) : String(line)
  }

  private static func contextLineText(_ line: Substring) -> String {
    line.hasPrefix(" ") ? String(line.dropFirst()) : String(line)
  }

  private static func parseHunkHeader(_ line: Substring) -> (oldStart: Int, newStart: Int)? {
    guard line.hasPrefix("@@") else { return nil }
    let pieces = line.split(separator: " ")
    guard
      let oldToken = pieces.first(where: { $0.hasPrefix("-") }),
      let newToken = pieces.first(where: { $0.hasPrefix("+") }),
      let oldStart = parseLineStart(oldToken),
      let newStart = parseLineStart(newToken)
    else {
      return nil
    }
    return (oldStart, newStart)
  }

  private static func parseLineStart(_ token: Substring) -> Int? {
    guard let number = token.dropFirst().split(separator: ",", maxSplits: 1).first,
      !number.isEmpty
    else {
      return nil
    }
    return Int(number)
  }

  private struct LineNumbers {
    let old: Int?
    let new: Int?

    static let none = Self(old: nil, new: nil)
  }

  private struct HunkPosition {
    let oldLine: Int
    let newLine: Int
    let nextOldStart: Int
    let nextNewStart: Int
    let hasSeenHunk: Bool
  }
}

struct DashboardReviewFileDiffRow: Equatable, Identifiable {
  enum Kind: Equatable {
    case addition
    case context
    case contextGap
    case deletion
    case hunk
    case metadata
  }

  let id: Int
  let kind: Kind
  let oldLine: Int?
  let newLine: Int?
  let diffPosition: Int?
  let text: String
  let contextGap: DashboardReviewFileContextGap?

  var unifiedPrefix: String {
    switch kind {
    case .addition: "+"
    case .deletion: "-"
    case .context: " "
    case .contextGap, .hunk, .metadata: ""
    }
  }

  var copyText: String {
    switch kind {
    case .addition, .context, .deletion:
      text
    case .contextGap, .hunk, .metadata:
      ""
    }
  }

  func lineNumber(on side: DashboardReviewFileDiffSide) -> Int? {
    switch side {
    case .old:
      oldLine
    case .new:
      newLine
    }
  }

  func matches(anchor: DashboardReviewFileThreadAnchor) -> Bool {
    if let position = anchor.diffPosition, position == diffPosition {
      return true
    }
    guard let line = anchor.line else { return false }
    if let side = anchor.side {
      return lineNumber(on: side) == line
    }
    return oldLine == line || newLine == line
  }
}

enum DashboardReviewFileDiffSide: String, Equatable, Hashable {
  case old
  case new

  init?(wireValue: String?) {
    guard let raw = wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return nil
    }
    if raw == "left" || raw == "old" {
      self = .old
    } else if raw == "right" || raw == "new" {
      self = .new
    } else {
      return nil
    }
  }
}

struct DashboardReviewFileContextGap: Equatable {
  let oldStart: Int?
  let newStart: Int?
  let oldHiddenCount: Int
  let newHiddenCount: Int

  var summary: String {
    let hidden = max(oldHiddenCount, newHiddenCount)
    if hidden == 1 {
      return "1 unchanged line omitted"
    }
    return "\(hidden) unchanged lines omitted"
  }
}

extension HarnessCodeLanguage {
  init(reviewLanguage: HarnessReviewFileLanguage) {
    switch reviewLanguage {
    case .diff:
      self = .diff
    case .feature:
      self = .feature
    case .generic:
      self = .generic
    case .go:
      self = .go
    case .javascript:
      self = .javascript
    case .json:
      self = .json
    case .markdown:
      self = .markdown
    case .rust:
      self = .rust
    case .shell:
      self = .shell
    case .swift:
      self = .swift
    case .typescript:
      self = .typescript
    case .vue:
      self = .vue
    case .yaml:
      self = .yaml
    }
  }
}
