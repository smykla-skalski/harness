// Pure helpers mirroring the daemon's path-to-language and image-MIME
// truth tables. Companion file to keep `ReviewFile.swift` under
// the 420-line cap.

import Foundation

private let harnessLanguageByBasename: [String: HarnessReviewFileLanguage] = [
  "_common_redirects": .config,
  "_headers": .config,
  "_redirects": .config,
  "changelog.md": .markdown,
  "codeowners": .codeowners,
  "containerfile": .dockerfile,
  "dockerfile": .dockerfile,
  "gemfile": .ruby,
  "gemfile.lock": .ruby,
  "go.mod": .goModule,
  "go.sum": .goModule,
  "makefile": .makefile,
  "package-lock.json": .json,
  "package.json": .json,
  "procfile": .config,
  "rakefile": .ruby,
  "readme.md": .markdown,
  "tsconfig.json": .json,
]

private let harnessLanguageByFilenamePrefix: [(String, HarnessReviewFileLanguage)] = [
  ("containerfile.", .dockerfile),
  ("dockerfile.", .dockerfile),
]

private let harnessLanguageByExtension: [String: HarnessReviewFileLanguage] = [
  "bash": .shell,
  "cjs": .javascript,
  "cts": .typescript,
  "css": .stylesheet,
  "diff": .diff,
  "dockerfile": .dockerfile,
  "dockerignore": .gitignore,
  "editorconfig": .config,
  "eslintignore": .gitignore,
  "feature": .feature,
  "fish": .shell,
  "gemspec": .ruby,
  "go": .go,
  "gotmpl": .template,
  "gitmodules": .config,
  "gitignore": .gitignore,
  "hcl": .terraform,
  "helmignore": .gitignore,
  "helmdocsignore": .gitignore,
  "htm": .html,
  "html": .html,
  "ini": .config,
  "js": .javascript,
  "jsx": .javascript,
  "json": .json,
  "jsonc": .json,
  "lua": .lua,
  "markdown": .markdown,
  "md": .markdown,
  "mdown": .markdown,
  "mk": .makefile,
  "mjs": .javascript,
  "mts": .typescript,
  "mustache": .template,
  "npmignore": .gitignore,
  "npmrc": .config,
  "nvmrc": .config,
  "patch": .diff,
  "prettierignore": .gitignore,
  "proto": .proto,
  "ps1": .powershell,
  "psd1": .powershell,
  "psm1": .powershell,
  "py": .python,
  "rb": .ruby,
  "rego": .rego,
  "releaserc": .config,
  "rs": .rust,
  "rspec": .config,
  "ruby-version": .config,
  "scss": .stylesheet,
  "service": .config,
  "sh": .shell,
  "sql": .sql,
  "swift": .swift,
  "ts": .typescript,
  "tftpl": .template,
  "tf": .terraform,
  "tfvars": .terraform,
  "tmpl": .template,
  "toml": .toml,
  "tpl": .template,
  "tsx": .typescript,
  "vue": .vue,
  "xml": .xml,
  "xsd": .xml,
  "xsl": .xml,
  "xslt": .xml,
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
  if let language = harnessLanguageByBasename[name] {
    return language
  }
  if let ext = harnessPathExtensionLowercased(forLastPathComponent: name),
    let language = harnessLanguageByExtension[ext]
  {
    return language
  }
  for (prefix, language) in harnessLanguageByFilenamePrefix where name.hasPrefix(prefix) {
    return language
  }
  return .generic
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
  guard let dotIndex = name.lastIndex(of: ".") else {
    return nil
  }
  if dotIndex == name.startIndex {
    let suffixStart = name.index(after: dotIndex)
    guard suffixStart < name.endIndex else { return nil }
    return String(name[suffixStart...])
  }
  return String(name[name.index(after: dotIndex)...])
}
