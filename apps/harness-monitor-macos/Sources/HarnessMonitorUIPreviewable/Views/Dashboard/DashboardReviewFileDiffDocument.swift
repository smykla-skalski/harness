import Foundation
import HarnessMonitorKit

struct DashboardReviewFileDiffDocument: Equatable {
  let path: String
  let language: HarnessReviewFileLanguage
  let rows: [DashboardReviewFileDiffRow]
  let truncated: Bool

  init(patch: ReviewFilePatch, language: HarnessReviewFileLanguage) {
    self.path = patch.path
    self.language = language
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
    for rawLine in splitPatchLines(patch) {
      let id = rows.count
      if let hunk = parseHunkHeader(rawLine) {
        oldLine = hunk.oldStart
        newLine = hunk.newStart
        rows.append(.init(id: id, kind: .hunk, oldLine: nil, newLine: nil, text: rawLine))
      } else if rawLine.hasPrefix("\\ No newline") {
        rows.append(.init(id: id, kind: .metadata, oldLine: nil, newLine: nil, text: rawLine))
      } else if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
        rows.append(
          .init(id: id, kind: .addition, oldLine: nil, newLine: newLine, text: dropPrefix(rawLine))
        )
        newLine += 1
      } else if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
        rows.append(
          .init(id: id, kind: .deletion, oldLine: oldLine, newLine: nil, text: dropPrefix(rawLine))
        )
        oldLine += 1
      } else {
        rows.append(
          .init(
            id: id,
            kind: .context,
            oldLine: oldLine,
            newLine: newLine,
            text: rawLine.hasPrefix(" ") ? dropPrefix(rawLine) : rawLine
          )
        )
        oldLine += 1
        newLine += 1
      }
    }
    return rows
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
}

struct DashboardReviewFileDiffRow: Equatable, Identifiable {
  enum Kind: Equatable {
    case addition
    case context
    case deletion
    case hunk
    case metadata
  }

  let id: Int
  let kind: Kind
  let oldLine: Int?
  let newLine: Int?
  let text: String

  var unifiedPrefix: String {
    switch kind {
    case .addition: "+"
    case .deletion: "-"
    case .context: " "
    case .hunk, .metadata: ""
    }
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
