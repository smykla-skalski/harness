import Foundation
import HarnessMonitorKit

struct DashboardReviewFileDiffDocument: Equatable {
  let path: String
  let language: HarnessReviewFileLanguage
  let rows: [DashboardReviewFileDiffRow]
  let truncated: Bool
  let headRefOid: String
  let longestCodeCharacterCount: Int

  init(patch: ReviewFilePatch, language: HarnessReviewFileLanguage, tabWidth: Int = 8) {
    self.path = patch.path
    self.language = language
    self.headRefOid = patch.headRefOid
    let lineCount = Self.estimatedLineCount(in: patch.patch)
    let interval = ReviewFilesPerf.beginDiffParse(path: patch.path, lineCount: lineCount)
    let parsed = Self.parseRows(
      from: patch.patch,
      estimatedLineCount: lineCount,
      tabWidth: tabWidth
    )
    self.rows = parsed.rows
    self.longestCodeCharacterCount = parsed.longestCodeCharacterCount
    ReviewFilesPerf.end(interval)
    self.truncated = patch.truncated
  }

  var isEmpty: Bool { rows.isEmpty }

  private static func parseRows(
    from patch: String,
    estimatedLineCount: Int,
    tabWidth: Int
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
      longestCodeCharacterCount = max(
        longestCodeCharacterCount,
        displayColumnCount(row.text)
      )
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
        let raw = sourceLineText(rawLine, hasSeenHunk: hasSeenHunk)
        appendRow(
          row(
            rows: rows,
            kind: hasSeenHunk ? .addition : .metadata,
            lines: .init(old: nil, new: hasSeenHunk ? normalizedLine(newLine) : nil),
            text: hasSeenHunk ? expandTabs(raw, tabWidth: tabWidth) : raw,
            rawText: raw,
            diffPosition: hasSeenHunk ? diffPosition : nil
          )
        )
        if hasSeenHunk {
          newLine += 1
          diffPosition += 1
        }
      } else if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
        let raw = sourceLineText(rawLine, hasSeenHunk: hasSeenHunk)
        appendRow(
          row(
            rows: rows,
            kind: hasSeenHunk ? .deletion : .metadata,
            lines: .init(old: hasSeenHunk ? normalizedLine(oldLine) : nil, new: nil),
            text: hasSeenHunk ? expandTabs(raw, tabWidth: tabWidth) : raw,
            rawText: raw,
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
        let raw = contextLineText(rawLine)
        appendRow(
          row(
            rows: rows,
            kind: hasSeenHunk ? .context : .metadata,
            lines: .init(
              old: hasSeenHunk ? normalizedLine(oldLine) : nil,
              new: hasSeenHunk ? normalizedLine(newLine) : nil
            ),
            text: hasSeenHunk ? expandTabs(raw, tabWidth: tabWidth) : raw,
            rawText: raw,
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
    rawText: String? = nil,
    diffPosition: Int? = nil
  ) -> DashboardReviewFileDiffRow {
    DashboardReviewFileDiffRow(
      id: rows.count,
      kind: kind,
      oldLine: lines.old,
      newLine: lines.new,
      diffPosition: diffPosition,
      text: text,
      rawText: rawText,
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

  /// Expands tabs to spaces on `tabWidth` stops, advancing by display columns
  /// so wide glyphs before a tab still align. This keeps the soft-wrap budget
  /// honest - a tab is one character but renders as many columns - and avoids
  /// Core Text's unpredictable default tab stops at draw time.
  private static func expandTabs(_ text: String, tabWidth: Int) -> String {
    guard tabWidth > 0, text.contains("\t") else { return text }
    var result = ""
    result.reserveCapacity(text.count + tabWidth)
    var column = 0
    for character in text {
      if character == "\t" {
        let advance = tabWidth - (column % tabWidth)
        result.append(String(repeating: " ", count: advance))
        column += advance
      } else {
        result.append(character)
        column += DashboardReviewFileDiffDisplayColumns.width(of: character)
      }
    }
    return result
  }

  private static func displayColumnCount(_ text: String) -> Int {
    text.reduce(0) { $0 + DashboardReviewFileDiffDisplayColumns.width(of: $1) }
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
