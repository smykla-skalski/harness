import Foundation
import HarnessMonitorKit

struct DashboardReviewFileDiffDocument: Equatable {
  let path: String
  let language: HarnessReviewFileLanguage
  let rows: [DashboardReviewFileDiffRow]
  let truncated: Bool
  let headRefOid: String

  init(patch: ReviewFilePatch, language: HarnessReviewFileLanguage) {
    self.path = patch.path
    self.language = language
    self.headRefOid = patch.headRefOid
    let lineCount = patch.patch.isEmpty ? 0 : patch.patch.split(separator: "\n").count
    let interval = ReviewFilesPerf.beginDiffParse(path: patch.path, lineCount: lineCount)
    self.rows = Self.parseRows(from: patch.patch)
    ReviewFilesPerf.end(interval)
    self.truncated = patch.truncated
  }

  var isEmpty: Bool { rows.isEmpty }

  var longestCodeCharacterCount: Int {
    rows.map(\.text.count).max() ?? 0
  }

  private static func parseRows(from patch: String) -> [DashboardReviewFileDiffRow] {
    guard !patch.isEmpty else { return [] }
    var rows: [DashboardReviewFileDiffRow] = []
    var oldLine = 0
    var newLine = 0
    var hasSeenHunk = false
    var diffPosition = 1
    for rawLine in splitPatchLines(patch) {
      if let hunk = parseHunkHeader(rawLine) {
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
        oldLine = hunk.oldStart
        newLine = hunk.newStart
        hasSeenHunk = true
        rows.append(
          row(
            rows: rows,
            kind: .hunk,
            text: rawLine,
            diffPosition: diffPosition
          )
        )
      } else if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
        rows.append(
          row(
            rows: rows,
            kind: hasSeenHunk ? .addition : .metadata,
            lines: .init(old: nil, new: hasSeenHunk ? normalizedLine(newLine) : nil),
            text: hasSeenHunk ? dropPrefix(rawLine) : rawLine,
            diffPosition: hasSeenHunk ? diffPosition : nil
          )
        )
        if hasSeenHunk {
          newLine += 1
          diffPosition += 1
        }
      } else if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
        rows.append(
          row(
            rows: rows,
            kind: hasSeenHunk ? .deletion : .metadata,
            lines: .init(old: hasSeenHunk ? normalizedLine(oldLine) : nil, new: nil),
            text: hasSeenHunk ? dropPrefix(rawLine) : rawLine,
            diffPosition: hasSeenHunk ? diffPosition : nil
          )
        )
        if hasSeenHunk {
          oldLine += 1
          diffPosition += 1
        }
      } else if shouldTreatAsMetadata(rawLine, hasSeenHunk: hasSeenHunk) {
        rows.append(row(rows: rows, kind: .metadata, text: rawLine))
      } else {
        rows.append(
          row(
            rows: rows,
            kind: hasSeenHunk ? .context : .metadata,
            lines: .init(
              old: hasSeenHunk ? normalizedLine(oldLine) : nil,
              new: hasSeenHunk ? normalizedLine(newLine) : nil
            ),
            text: rawLine.hasPrefix(" ") ? dropPrefix(rawLine) : rawLine,
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
    return rows
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

  private static func shouldTreatAsMetadata(_ line: String, hasSeenHunk: Bool) -> Bool {
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

  private static func splitPatchLines(_ patch: String) -> [String] {
    var parts = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if patch.hasSuffix("\n"), parts.last?.isEmpty == true {
      parts.removeLast()
    }
    return parts
  }

  private static func dropPrefix(_ line: String) -> String {
    String(line.dropFirst())
  }

  private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
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

@MainActor
final class DashboardReviewFileDiffDocumentCache {
  private struct Key: Hashable {
    let path: String
    let language: HarnessReviewFileLanguage
    let patch: String
    let truncated: Bool
    let headRefOid: String
  }

  private var documents: [Key: DashboardReviewFileDiffDocument] = [:]
  private var keys: [Key] = []
  private let limit: Int

  init(limit: Int = 12) {
    self.limit = limit
  }

  func document(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage
  ) -> DashboardReviewFileDiffDocument {
    let key = Key(
      path: patch.path,
      language: language,
      patch: patch.patch,
      truncated: patch.truncated,
      headRefOid: patch.headRefOid
    )
    if let document = documents[key] {
      return document
    }
    let document = DashboardReviewFileDiffDocument(patch: patch, language: language)
    documents[key] = document
    keys.append(key)
    evictIfNeeded()
    return document
  }

  private func evictIfNeeded() {
    while keys.count > limit, let key = keys.first {
      keys.removeFirst()
      documents.removeValue(forKey: key)
    }
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
    case .generic:
      self = .generic
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
    case .yaml:
      self = .yaml
    }
  }
}
