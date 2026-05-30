import Foundation

extension HarnessCodeLanguage {
  /// Resolves the language for a fenced code block. An explicit info string
  /// always wins, even when unrecognized: a tag like `text` or `log` is the
  /// author asking for plain output. A bare fence (empty info) carries no
  /// signal, so we sniff the content for the few high-confidence shapes that
  /// get pasted into PR bodies without a tag.
  static func resolvedForFence(info: String, source: String) -> HarnessCodeLanguage {
    let explicit = HarnessCodeLanguage(infoString: info)
    guard explicit == .generic, info.isEmpty else { return explicit }
    return inferredFromContent(source) ?? .generic
  }

  /// Best-effort language guess from code-block content alone, scoped to the
  /// shapes that show up unlabeled in PR bodies: shell sessions, JSON, and
  /// diffs. Returns nil when nothing matches confidently so the caller keeps
  /// `.generic` rather than mis-colouring arbitrary prose.
  static func inferredFromContent(_ source: String) -> HarnessCodeLanguage? {
    CodeFenceLanguageInterpreter(source: source)?.inferredLanguage
  }

  private struct CodeFenceLanguageInterpreter {
    let source: String
    let contentRange: Range<String.Index>

    init?(source: String) {
      var lowerBound = source.startIndex
      while lowerBound < source.endIndex, source[lowerBound].isWhitespace {
        source.formIndex(after: &lowerBound)
      }

      var upperBound = source.endIndex
      while lowerBound < upperBound {
        let candidate = source.index(before: upperBound)
        guard source[candidate].isWhitespace else { break }
        upperBound = candidate
      }

      guard lowerBound < upperBound else { return nil }
      self.source = source
      contentRange = lowerBound..<upperBound
    }

    var inferredLanguage: HarnessCodeLanguage? {
      let scan = contentScan()
      if scan.looksLikeDiff { return .diff }
      if contentLooksLikeJSON { return .json }
      if scan.looksLikeShell { return .shell }
      return nil
    }

    private var contentLooksLikeJSON: Bool {
      let first = source[contentRange.lowerBound]
      let last = source[source.index(before: contentRange.upperBound)]
      let object = first == "{" && last == "}"
      let array = first == "[" && last == "]"
      // A quote is what separates real JSON from a shell brace group or a `[ -f x ]`
      // test, both of which open with the same bracket.
      return (object || array) && source[contentRange].contains("\"")
    }

    private func contentScan() -> ContentScan {
      var signals = ScanSignals()

      var lineStart = contentRange.lowerBound
      while lineStart < contentRange.upperBound {
        let lineEnd =
          source[lineStart..<contentRange.upperBound].firstIndex(of: "\n")
          ?? contentRange.upperBound
        scanLine(lineStart..<lineEnd, into: &signals)

        guard lineEnd < contentRange.upperBound else { break }
        lineStart = source.index(after: lineEnd)
      }

      let firstWordIsShellLeader =
        signals.firstWordRange.map {
          HarnessCodeLanguage.shellCommandLeaders.contains(String(source[$0]))
        } ?? false
      return ContentScan(
        looksLikeDiff: signals.hasDiffHeader || signals.hasDiffHunk
          || (signals.hasOldHeader && signals.hasNewHeader),
        looksLikeShell: signals.hasPrompt || firstWordIsShellLeader
      )
    }

    private func scanLine(
      _ lineRange: Range<String.Index>,
      into signals: inout ScanSignals
    ) {
      let line = source[lineRange]
      if line.hasPrefix("diff --git ") {
        signals.hasDiffHeader = true
      }
      if line.hasPrefix("@@ "), line.dropFirst(3).contains("@@") {
        signals.hasDiffHunk = true
      }
      if line.hasPrefix("--- ") {
        signals.hasOldHeader = true
      } else if line.hasPrefix("+++ ") {
        signals.hasNewHeader = true
      }

      var bodyStart = lineRange.lowerBound
      while bodyStart < lineRange.upperBound, source[bodyStart] == " " {
        source.formIndex(after: &bodyStart)
      }
      guard hasNonWhitespace(in: bodyStart..<lineRange.upperBound) else {
        return
      }

      let body = source[bodyStart..<lineRange.upperBound]
      if body.hasPrefix("$ ") || body.hasPrefix("% ") {
        signals.hasPrompt = true
      }
      if signals.firstWordRange == nil {
        var wordEnd = bodyStart
        while wordEnd < lineRange.upperBound,
          source[wordEnd] != " ",
          source[wordEnd] != "\t"
        {
          source.formIndex(after: &wordEnd)
        }
        signals.firstWordRange = bodyStart..<wordEnd
      }
    }

    private func hasNonWhitespace(in range: Range<String.Index>) -> Bool {
      var index = range.lowerBound
      while index < range.upperBound {
        if !source[index].isWhitespace { return true }
        source.formIndex(after: &index)
      }
      return false
    }
  }

  private struct ScanSignals {
    var hasOldHeader = false
    var hasNewHeader = false
    var hasPrompt = false
    var hasDiffHeader = false
    var hasDiffHunk = false
    var firstWordRange: Range<String.Index>?
  }

  private struct ContentScan {
    let looksLikeDiff: Bool
    let looksLikeShell: Bool
  }

  /// First tokens common enough in pasted terminal output to identify a shell
  /// session without a `$`/`%` prompt. Kept conservative: each is a binary that
  /// rarely opens a line of prose or another language's source.
  private static let shellCommandLeaders: Set<String> = [
    "apt", "apt-get", "aws", "brew", "cargo", "cat", "cd", "chmod", "chown",
    "cp", "curl", "df", "dnf", "docker", "echo", "export", "find", "gcloud",
    "git", "go", "gradle", "grep", "helm", "journalctl", "kubectl", "ln",
    "ls", "make", "mkdir", "mv", "npm", "pip", "pnpm", "ps", "python",
    "python3", "rm", "scp", "sed", "source", "ssh", "sudo", "systemctl",
    "tar", "terraform", "wget", "yarn", "yum",
  ]
}
