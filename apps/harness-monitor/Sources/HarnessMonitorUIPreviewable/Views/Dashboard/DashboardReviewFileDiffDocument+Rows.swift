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
    case .codeowners:
      self = .codeowners
    case .config:
      self = .config
    case .dockerfile:
      self = .dockerfile
    case .diff:
      self = .diff
    case .feature:
      self = .feature
    case .generic:
      self = .generic
    case .go:
      self = .go
    case .gitignore:
      self = .gitignore
    case .goModule:
      self = .goModule
    case .html:
      self = .html
    case .javascript:
      self = .javascript
    case .json:
      self = .json
    case .lua:
      self = .lua
    case .makefile:
      self = .makefile
    case .markdown:
      self = .markdown
    case .powershell:
      self = .powershell
    case .proto:
      self = .proto
    case .python:
      self = .python
    case .rego:
      self = .rego
    case .rust:
        self = .rust
    case .ruby:
      self = .ruby
    case .shell:
      self = .shell
    case .sql:
      self = .sql
    case .stylesheet:
      self = .stylesheet
    case .swift:
      self = .swift
    case .template:
      self = .template
    case .terraform:
      self = .terraform
    case .toml:
      self = .toml
    case .typescript:
      self = .typescript
    case .vue:
      self = .vue
    case .xml:
      self = .xml
    case .yaml:
      self = .yaml
    }
  }
}
