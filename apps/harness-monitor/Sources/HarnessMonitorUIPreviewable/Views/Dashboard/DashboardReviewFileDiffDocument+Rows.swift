import HarnessMonitorKit

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
  /// Display text with tabs expanded to spaces; what the grid measures and draws.
  let text: String
  /// Original source line (tabs preserved) used for copy and anchors.
  let rawText: String
  let contextGap: DashboardReviewFileContextGap?

  init(
    id: Int,
    kind: Kind,
    oldLine: Int?,
    newLine: Int?,
    diffPosition: Int?,
    text: String,
    rawText: String? = nil,
    contextGap: DashboardReviewFileContextGap?
  ) {
    self.id = id
    self.kind = kind
    self.oldLine = oldLine
    self.newLine = newLine
    self.diffPosition = diffPosition
    self.text = text
    self.rawText = rawText ?? text
    self.contextGap = contextGap
  }

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
      rawText
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
    case .goModule:
      self = .goModule
    default:
      self = Self(rawValue: reviewLanguage.rawValue) ?? .generic
    }
  }
}
