import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness markdown parser")
struct HarnessMarkdownParserTests {
  @Test("Parser handles GitHub-style PR bodies")
  func parsesGitHubStyleBlocks() {
    let document = HarnessMarkdownParser.parse(
      """
      # Release notes

      This is **ready** with `inline` code.

      > Keep this visible.

      - [x] Ship native rendering
        - nested task

      3. Ordered item

      | Name | Value |
      | --- | --- |
      | status | green |

      ```swift
      let value = true
      ```

      <div>safe text</div>
      """
    )

    #expect(document.blocks.count == 8)
    guard case .heading(1, let heading)? = document.blocks.first else {
      Issue.record("Expected level one heading")
      return
    }
    #expect(heading == [.text("Release notes")])

    guard case .unorderedList(let items) = document.blocks[3] else {
      Issue.record("Expected task list")
      return
    }
    #expect(items.first?.checkbox == true)
    #expect(items.first?.blocks.count == 2)

    guard case .table(let table) = document.blocks[5] else {
      Issue.record("Expected table")
      return
    }
    #expect(table.headers.count == 2)
    #expect(table.rows.count == 1)

    guard case .codeBlock(let language, let source, let tokens) = document.blocks[6] else {
      Issue.record("Expected Swift code block")
      return
    }
    #expect(language == .swift)
    #expect(source == "let value = true")
    #expect(tokens.contains(.init(text: "let", kind: .keyword)))

    guard case .html(let html) = document.blocks[7] else {
      Issue.record("Expected raw HTML text")
      return
    }
    #expect(html == "<div>safe text</div>")
  }

  @Test("Malformed fences parse as code through end of source")
  func preservesMalformedFencesAsCodeUntilEnd() {
    let document = HarnessMarkdownParser.parse(
      """
      ```rust
      fn main() {}
      """
    )

    guard case .codeBlock(let language, let source, let tokens)? = document.blocks.first else {
      Issue.record("Expected code block")
      return
    }
    #expect(language == .rust)
    #expect(source == "fn main() {}")
    #expect(tokens.contains(.init(text: "fn", kind: .keyword)))
  }

  @Test("Inline parser handles common marks")
  func inlineParserHandlesCommonMarks() {
    let inlines = HarnessMarkdownInlineParser.parse(
      #"A **bold _nested_** ~~gone~~ `code` [site](https://example.com) <a@b.test> https://harness.local"#
    )

    #expect(inlines.contains(.strong([.text("bold "), .emphasis([.text("nested")])])))
    #expect(inlines.contains(.strikethrough([.text("gone")])))
    #expect(inlines.contains(.code("code")))
    #expect(inlines.contains(.link(label: [.text("site")], destination: "https://example.com")))
    #expect(inlines.contains(.autolink("a@b.test")))
    #expect(inlines.contains(.autolink("https://harness.local")))
  }

  @Test("Code highlighter covers curated languages")
  func codeHighlighterCoversCuratedLanguages() {
    #expect(HarnessCodeHighlighter.highlight("let value = true", language: .swift).contains(.init(text: "let", kind: .keyword)))
    #expect(HarnessCodeHighlighter.highlight("fn main() {}", language: .rust).contains(.init(text: "fn", kind: .keyword)))
    #expect(HarnessCodeHighlighter.highlight("if test; then echo ok; fi", language: .shell).contains(.init(text: "then", kind: .keyword)))
    #expect(HarnessCodeHighlighter.highlight(#"{"ok":true}"#, language: .json).contains(.init(text: #""ok""#, kind: .property)))
    #expect(HarnessCodeHighlighter.highlight("ok: true", language: .yaml).contains(.init(text: "ok", kind: .property)))
    #expect(HarnessCodeHighlighter.highlight("# Heading", language: .markdown).contains(.init(text: "# Heading", kind: .heading)))
    #expect(HarnessCodeHighlighter.highlight("+added", language: .diff).contains(.init(text: "+added", kind: .inserted)))
    #expect(HarnessCodeHighlighter.highlight("plain", language: .generic) == [.init(text: "plain", kind: .plain)])
  }
}

@Suite("Harness markdown source contracts")
struct HarnessMarkdownSourceContractTests {
  @Test("Markdown renderer does not depend on the removed package or feature flag")
  func markdownRendererDoesNotDependOnRemovedPackageOrFeatureFlag() throws {
    let forbidden = ["Text" + "ual", "HARNESS_FEATURE_" + "TEXTUAL", "import Text" + "ual"]
    let files = [
      "apps/harness-monitor-macos/Tuist/Package.swift",
      "apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/FeatureFlags.swift",
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Shared/HarnessMonitorMarkdownText.swift",
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardItemManagementSupport.swift",
    ]

    for file in files {
      let source = try readRepositoryFile(file)
      for token in forbidden {
        #expect(!source.contains(token), "\(file) still contains \(token)")
      }
    }
    #expect(!FileManager.default.fileExists(atPath: repositoryPath("apps/harness-monitor-macos/features/" + "text" + "ual.yml")))
  }

  @Test("Markdown parser support stays scanner-based")
  func markdownParserSupportStaysScannerBased() throws {
    let forbidden = ["Re" + "gex", "NSRegular" + "Expression", ".regular" + "Expression"]
    let supportRoot = repositoryPath(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/Markdown"
    )
    let files = try FileManager.default.contentsOfDirectory(atPath: supportRoot)
      .filter { $0.hasSuffix(".swift") }

    for file in files {
      let source = try String(contentsOfFile: supportRoot + "/" + file, encoding: .utf8)
      for token in forbidden {
        #expect(!source.contains(token), "\(file) contains scanner-forbidden token \(token)")
      }
    }
  }

  private func readRepositoryFile(_ relativePath: String) throws -> String {
    try String(contentsOfFile: repositoryPath(relativePath), encoding: .utf8)
  }

  private func repositoryPath(_ relativePath: String) -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(relativePath)
      .path
  }
}
