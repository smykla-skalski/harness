// Pure helpers mirroring the daemon's path-to-language and image-MIME
// truth tables. Companion file to keep `ReviewFile.swift` under
// the 420-line cap.

import Foundation

private let harnessGenericFilenames: Set<String> = [
  "containerfile",
  "dockerfile",
  "makefile",
]

private let harnessJSONFilenames: Set<String> = [
  "package-lock.json",
  "package.json",
  "tsconfig.json",
]

private let harnessMarkdownFilenames: Set<String> = [
  "changelog.md",
  "readme.md",
]

private let harnessLanguageByExtension: [String: HarnessReviewFileLanguage] = [
  "bash": .shell,
  "diff": .diff,
  "fish": .shell,
  "json": .json,
  "jsonc": .json,
  "markdown": .markdown,
  "md": .markdown,
  "mdown": .markdown,
  "patch": .diff,
  "rs": .rust,
  "sh": .shell,
  "swift": .swift,
  "yaml": .yaml,
  "yml": .yaml,
  "zsh": .shell,
]

/// Truth-table inference mirroring the daemon's `infer_language`.
///
/// Kept verbatim so cached metadata round-trips have stable values even
/// when the daemon has not had a chance to annotate `language_hint`.
public func harnessInferLanguage(forPath path: String) -> HarnessReviewFileLanguage {
  let name = harnessLastPathComponentLowercased(path)
  if harnessGenericFilenames.contains(name) {
    return .generic
  }
  if harnessJSONFilenames.contains(name) {
    return .json
  }
  if harnessMarkdownFilenames.contains(name) {
    return .markdown
  }
  guard let ext = harnessPathExtensionLowercased(forLastPathComponent: name) else {
    return .generic
  }
  return harnessLanguageByExtension[ext] ?? .generic
}

/// Returns true when the path ends in a supported image extension.
public func harnessIsImagePath(_ path: String) -> Bool {
  harnessImageMime(forPath: path) != nil
}

/// MIME inference mirroring the daemon helper. Returns nil for non-image
/// paths.
public func harnessImageMime(forPath path: String) -> HarnessReviewImageMime? {
  let name = harnessLastPathComponentLowercased(path)
  guard let ext = harnessPathExtensionLowercased(forLastPathComponent: name) else {
    return nil
  }
  switch ext {
  case "png": return .png
  case "jpg", "jpeg": return .jpeg
  case "gif": return .gif
  case "svg": return .svg
  default: return nil
  }
}

/// Matches a path against the supplied (already-compiled) generated-file
/// patterns. The caller should provide pre-compiled `NSRegularExpression`s
/// so view bodies don't re-compile per-row.
public func harnessIsGeneratedPath(
  _ path: String,
  patterns: [NSRegularExpression]
) -> Bool {
  let range = NSRange(path.startIndex..<path.endIndex, in: path)
  for regex in patterns where regex.firstMatch(in: path, options: [], range: range) != nil {
    return true
  }
  return false
}

private func harnessLastPathComponentLowercased(_ path: String) -> String {
  guard let slashIndex = path.lastIndex(of: "/") else {
    return path.lowercased()
  }
  return path[path.index(after: slashIndex)...].lowercased()
}

private func harnessPathExtensionLowercased(forLastPathComponent name: String) -> String? {
  guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
    return nil
  }
  return String(name[name.index(after: dotIndex)...])
}
