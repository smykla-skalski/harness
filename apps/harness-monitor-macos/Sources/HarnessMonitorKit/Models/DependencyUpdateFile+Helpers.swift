// Pure helpers mirroring the daemon's path-to-language and image-MIME
// truth tables. Companion file to keep `DependencyUpdateFile.swift` under
// the 420-line cap.

import Foundation

/// Truth-table inference mirroring the daemon's `infer_language`.
///
/// Kept verbatim so cached metadata round-trips have stable values even
/// when the daemon has not had a chance to annotate `language_hint`.
public func harnessInferLanguage(forPath path: String) -> HarnessDependencyFileLanguage {
  let lower = path.lowercased()
  if let name = lower.split(separator: "/").last.map(String.init) {
    switch name {
    case "dockerfile", "containerfile":
      return .generic
    case "makefile":
      return .generic
    case "package.json", "package-lock.json", "tsconfig.json":
      return .json
    case "readme.md", "changelog.md":
      return .markdown
    default:
      break
    }
  }
  guard let ext = lower.split(separator: ".").last.map(String.init), ext != lower else {
    return .generic
  }
  switch ext {
  case "swift": return .swift
  case "rs": return .rust
  case "sh", "bash", "zsh", "fish": return .shell
  case "json", "jsonc": return .json
  case "yaml", "yml": return .yaml
  case "md", "markdown", "mdown": return .markdown
  case "patch", "diff": return .diff
  default: return .generic
  }
}

/// Returns true when the path ends in a supported image extension.
public func harnessIsImagePath(_ path: String) -> Bool {
  harnessImageMime(forPath: path) != nil
}

/// MIME inference mirroring the daemon helper. Returns nil for non-image
/// paths.
public func harnessImageMime(forPath path: String) -> HarnessDependencyImageMime? {
  let lower = path.lowercased()
  guard let ext = lower.split(separator: ".").last.map(String.init), ext != lower else {
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
  for regex in patterns {
    if regex.firstMatch(in: path, options: [], range: range) != nil {
      return true
    }
  }
  return false
}
