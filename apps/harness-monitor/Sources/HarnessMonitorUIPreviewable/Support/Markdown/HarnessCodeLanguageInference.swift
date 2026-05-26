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
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if contentLooksLikeDiff(lines) { return .diff }
    if contentLooksLikeJSON(trimmed) { return .json }
    if contentLooksLikeShell(lines) { return .shell }
    return nil
  }

  private static func contentLooksLikeDiff(_ lines: [String]) -> Bool {
    if lines.contains(where: { $0.hasPrefix("diff --git ") }) { return true }
    if lines.contains(where: { $0.hasPrefix("@@ ") && $0.dropFirst(3).contains("@@") }) {
      return true
    }
    let hasOldHeader = lines.contains { $0.hasPrefix("--- ") }
    let hasNewHeader = lines.contains { $0.hasPrefix("+++ ") }
    return hasOldHeader && hasNewHeader
  }

  private static func contentLooksLikeJSON(_ trimmed: String) -> Bool {
    guard let first = trimmed.first, let last = trimmed.last else { return false }
    let object = first == "{" && last == "}"
    let array = first == "[" && last == "]"
    // A quote is what separates real JSON from a shell brace group or a `[ -f x ]`
    // test, both of which open with the same bracket.
    return (object || array) && trimmed.contains("\"")
  }

  private static func contentLooksLikeShell(_ lines: [String]) -> Bool {
    let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard let firstLine = nonBlank.first else { return false }
    let hasPrompt = nonBlank.contains { line in
      let body = line.drop(while: { $0 == " " })
      return body.hasPrefix("$ ") || body.hasPrefix("% ")
    }
    if hasPrompt { return true }
    let firstWord = firstLine.drop(while: { $0 == " " }).prefix { $0 != " " && $0 != "\t" }
    return shellCommandLeaders.contains(String(firstWord))
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
