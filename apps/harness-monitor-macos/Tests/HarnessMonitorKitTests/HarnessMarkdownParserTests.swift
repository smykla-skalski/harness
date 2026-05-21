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
      Issue.record("Expected HTML text")
      return
    }
    #expect(html == [.text("safe text")])
  }

  @Test("Parser renders supported markdown HTML and drops comments")
  func parserRendersSupportedMarkdownHTML() {
    let document = HarnessMarkdownParser.parse(
      """
      <p>Hello <strong>bold</strong> <em>em</em> <code>x</code><br><a href="https://example.com" title="Docs">link</a></p>
      <!-- hidden comment -->
      <script>hidden()</script>
      """
    )

    guard case .html(let inlines)? = document.blocks.first else {
      Issue.record("Expected rendered HTML inline block")
      return
    }
    #expect(inlines.contains(.strong([.text("bold")])))
    #expect(inlines.contains(.emphasis([.text("em")])))
    #expect(inlines.contains(.code("x")))
    #expect(inlines.contains(.lineBreak))
    #expect(
      inlines.contains(
        .link(label: [.text("link")], destination: "https://example.com", title: "Docs")))
    #expect(!inlines.contains(.text("hidden comment")))
  }

  @Test("Parser renders HTML details as disclosure content")
  func parserRendersHTMLDetails() {
    let document = HarnessMarkdownParser.parse(
      """
      <details open>
      <summary><strong>More</strong> info</summary>

      Body with <em>inline</em> HTML.
      <!-- hidden -->
      </details>
      """
    )

    guard case .details(let details)? = document.blocks.first else {
      Issue.record("Expected details block")
      return
    }
    #expect(details.isOpen)
    #expect(details.summary == [.strong([.text("More")]), .text(" info")])
    guard case .paragraph(let body)? = details.blocks.first else {
      Issue.record("Expected details body paragraph")
      return
    }
    #expect(body.contains(.emphasis([.text("inline")])))
    #expect(!body.contains(.text("hidden")))
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
    #expect(
      inlines.contains(
        .link(label: [.text("site")], destination: "https://example.com", title: nil)))
    #expect(inlines.contains(.autolink("a@b.test")))
    #expect(inlines.contains(.autolink("https://harness.local")))
  }

  @Test("Inline parser distinguishes references and soft breaks")
  func inlineParserHandlesReferencesAndBreaks() {
    let references = [
      "h": HarnessMarkdownReference(destination: "https://example.com", title: "Docs"),
      "collapsed": HarnessMarkdownReference(destination: "https://collapsed.example", title: nil),
    ]
    let inlines = HarnessMarkdownInlineParser.parse(
      "See [Harness][h] and [collapsed][]\nsoft  \nslash\\\nnext.",
      references: references
    )

    #expect(
      inlines.contains(
        .link(label: [.text("Harness")], destination: "https://example.com", title: "Docs")))
    #expect(
      inlines.contains(
        .link(label: [.text("collapsed")], destination: "https://collapsed.example", title: nil)))
    #expect(inlines.contains(.softBreak))
    #expect(inlines.filter { $0 == .lineBreak }.count == 2)
  }

  @Test("Block parser handles setext headings and table alignment")
  func blockParserHandlesSetextHeadingsAndTableAlignment() {
    let document = HarnessMarkdownParser.parse(
      """
      Title
      =====

      | Left | Center | Right |
      | :--- | :----: | ----: |
      | l | c | r |
      """
    )

    guard case .heading(1, let heading)? = document.blocks.first else {
      Issue.record("Expected setext heading")
      return
    }
    #expect(heading == [.text("Title")])

    guard case .table(let table)? = document.blocks.dropFirst().first else {
      Issue.record("Expected aligned table")
      return
    }
    #expect(table.alignments == [.leading, .center, .trailing])
    #expect(table.rows.count == 1)
  }

  @Test("Block parser handles long fence closers and ordered parentheses")
  func blockParserHandlesFenceAndOrderedParity() {
    let document = HarnessMarkdownParser.parse(
      """
      ```swift
      let value = true
      ````

      7) parenthesized item
      """
    )

    guard case .codeBlock(let language, let source, _)? = document.blocks.first else {
      Issue.record("Expected code block")
      return
    }
    #expect(language == .swift)
    #expect(source == "let value = true")

    guard case .orderedList(let start, let items)? = document.blocks.dropFirst().first else {
      Issue.record("Expected ordered list")
      return
    }
    #expect(start == 7)
    #expect(items.count == 1)
  }

  @Test("Parser exits early when detached work is cancelled")
  func parserHonorsCancellation() {
    let document = HarnessMarkdownParser.parse(
      "# Title\n\nBody",
      shouldCancel: { true }
    )

    #expect(document == .empty)
  }

  @Test("Code highlighter covers curated languages")
  func codeHighlighterCoversCuratedLanguages() {
    #expect(
      HarnessCodeHighlighter.highlight("let value = true", language: .swift).contains(
        .init(text: "let", kind: .keyword)))
    #expect(
      HarnessCodeHighlighter.highlight("fn main() {}", language: .rust).contains(
        .init(text: "fn", kind: .keyword)))
    #expect(
      HarnessCodeHighlighter.highlight("if test; then echo ok; fi", language: .shell).contains(
        .init(text: "then", kind: .keyword)))
    #expect(
      HarnessCodeHighlighter.highlight(#"{"ok":true}"#, language: .json).contains(
        .init(text: #""ok""#, kind: .property)))
    #expect(
      HarnessCodeHighlighter.highlight("ok: true", language: .yaml).contains(
        .init(text: "ok", kind: .property)))
    #expect(
      HarnessCodeHighlighter.highlight("# Heading", language: .markdown).contains(
        .init(text: "# Heading", kind: .heading)))
    #expect(
      HarnessCodeHighlighter.highlight("+added", language: .diff).contains(
        .init(text: "+added", kind: .inserted)))
    #expect(
      HarnessCodeHighlighter.highlight("plain", language: .generic) == [
        .init(text: "plain", kind: .plain)
      ])
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
    #expect(
      !FileManager.default.fileExists(
        atPath: repositoryPath("apps/harness-monitor-macos/features/" + "text" + "ual.yml")))
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

  @Test("Markdown render pipeline explicitly cancels detached work")
  func markdownRenderPipelineCancelsDetachedWork() throws {
    let renderer = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Shared/HarnessMonitorMarkdownText.swift"
    )
    let parser = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/Markdown/HarnessMarkdownParser.swift"
    )

    #expect(renderer.contains("withTaskCancellationHandler"))
    #expect(renderer.contains("worker.cancel()"))
    #expect(parser.contains("shouldCancel"))
  }

  @Test("Markdown image flow participates in baseline alignment")
  func markdownImageFlowParticipatesInBaselineAlignment() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMarkdownInlineFlowView.swift"
    )

    #expect(source.contains(".alignmentGuide(.firstTextBaseline)"))
    #expect(source.contains("dimensions[VerticalAlignment.center]"))
  }

  private func readRepositoryFile(_ relativePath: String) throws -> String {
    try String(contentsOfFile: repositoryPath(relativePath), encoding: .utf8)
  }

  private func repositoryPath(_ relativePath: String) -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(relativePath)
      .path
  }
}
