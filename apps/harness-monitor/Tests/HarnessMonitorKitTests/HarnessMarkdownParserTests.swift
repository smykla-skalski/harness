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

    guard case .codeBlock(let language, let highlights) = document.blocks[6] else {
      Issue.record("Expected Swift code block")
      return
    }
    #expect(language == .swift)
    #expect(highlights.source == "let value = true")
    #expect(highlights.contains(.init(text: "let", kind: .keyword)))

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
      <p>Hello <strong>bold</strong> <em>em</em> <code>x</code><br>\
      <a href="https://example.com" title="Docs">link</a></p>
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

  @Test("Parser recognizes GitHub alerts with trailing marker whitespace")
  func parserRecognizesGitHubAlerts() {
    let document = HarnessMarkdownParser.parse(
      """
      > [!NOTE]   
      > Useful information that users should know.
      """
    )

    guard case .alert(let alert)? = document.blocks.first else {
      Issue.record("Expected alert block")
      return
    }
    #expect(alert.kind == .note)
    guard case .paragraph(let body)? = alert.blocks.first else {
      Issue.record("Expected alert paragraph body")
      return
    }
    #expect(body == [.text("Useful information that users should know.")])
  }

  @Test("Parser recognizes GitHub alerts after a leading blank quote line")
  func parserRecognizesGitHubAlertsAfterLeadingBlankQuoteLine() {
    let document = HarnessMarkdownParser.parse(
      """
      >
      > [!WARNING]
      > Check configuration before continuing.
      """
    )

    guard case .alert(let alert)? = document.blocks.first else {
      Issue.record("Expected alert block after blank quote line")
      return
    }
    #expect(alert.kind == .warning)
    guard case .paragraph(let body)? = alert.blocks.first else {
      Issue.record("Expected alert paragraph body")
      return
    }
    #expect(body == [.text("Check configuration before continuing.")])
  }

  @Test("Parser recognizes legacy GitHub note quotes with emoji headers")
  func parserRecognizesLegacyGitHubNoteQuotes() {
    let document = HarnessMarkdownParser.parse(
      """
      > ℹ️ **Note**
      > This PR body was truncated due to platform limits.
      """
    )

    guard case .alert(let alert)? = document.blocks.first else {
      Issue.record("Expected legacy note quote to parse as alert")
      return
    }
    #expect(alert.kind == .note)
    guard case .paragraph(let body)? = alert.blocks.first else {
      Issue.record("Expected legacy note body paragraph")
      return
    }
    #expect(body == [.text("This PR body was truncated due to platform limits.")])
  }

  @Test("Unknown GitHub alert markers fall back to plain block quotes")
  func unknownGitHubAlertMarkersFallbackToBlockQuotes() {
    let document = HarnessMarkdownParser.parse(
      """
      > [!UNKNOWN]
      > This stays a quote.
      """
    )

    guard case .blockQuote(let blocks)? = document.blocks.first else {
      Issue.record("Expected plain block quote")
      return
    }
    guard case .paragraph(let body)? = blocks.first else {
      Issue.record("Expected quote paragraph body")
      return
    }
    #expect(body == [.text("[!UNKNOWN]"), .softBreak, .text("This stays a quote.")])
  }

  @Test("Malformed fences parse as code through end of source")
  func preservesMalformedFencesAsCodeUntilEnd() {
    let document = HarnessMarkdownParser.parse(
      """
      ```rust
      fn main() {}
      """
    )

    guard case .codeBlock(let language, let highlights)? = document.blocks.first else {
      Issue.record("Expected code block")
      return
    }
    #expect(language == .rust)
    #expect(highlights.source == "fn main() {}")
    #expect(highlights.contains(.init(text: "fn", kind: .keyword)))
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

    guard case .codeBlock(let language, let highlights)? = document.blocks.first else {
      Issue.record("Expected code block")
      return
    }
    #expect(language == .swift)
    #expect(highlights.source == "let value = true")

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
      HarnessCodeHighlighter.highlight("Feature: search", language: .feature).contains(
        .init(text: "Feature:", kind: .heading)))
    #expect(
      HarnessCodeHighlighter.highlight("func main() {}", language: .go).contains(
        .init(text: "func", kind: .keyword)))
    #expect(
      HarnessCodeHighlighter.highlight("function run() { return true }", language: .javascript)
        .contains(.init(text: "function", kind: .keyword)))
    #expect(
      HarnessCodeHighlighter.highlight("interface User { name: string }", language: .typescript)
        .contains(.init(text: "interface", kind: .keyword)))
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
      HarnessCodeHighlighter.highlight("<template></template>", language: .vue).contains(
        .init(text: "template", kind: .type)))
    #expect(
      HarnessCodeHighlighter.highlight("+added", language: .diff).contains(
        .init(text: "+added", kind: .inserted)))
    #expect(
      HarnessCodeHighlighter.highlight("plain", language: .generic) == [
        .init(text: "plain", kind: .plain)
      ])
  }

  @Test("Code highlighter keeps Go raw strings opaque")
  func codeHighlighterKeepsGoRawStringsOpaque() {
    let tokens = HarnessCodeHighlighter.highlight(
      """
      package main

      func main() {
        raw := `func if return`
      }
      """,
      language: .go
    )

    #expect(tokens.contains(.init(text: "`func if return`", kind: .string)))
    #expect(HarnessCodeLanguage(infoString: "go") == .go)
    #expect(HarnessCodeLanguage(infoString: "golang") == .go)
    #expect(HarnessCodeLanguage.go.displayName == "Go")
  }

  @Test("Code highlighter handles JavaScript and TypeScript strings")
  func codeHighlighterHandlesJavaScriptAndTypeScriptStrings() {
    let javascriptTokens = HarnessCodeHighlighter.highlight(
      #"const message = `say \`hi\``"#,
      language: .javascript
    )
    let typescriptTokens = HarnessCodeHighlighter.highlight(
      "type Greeting = 'hello'",
      language: .typescript
    )

    #expect(javascriptTokens.contains(.init(text: #"`say \`hi\``"#, kind: .string)))
    #expect(typescriptTokens.contains(.init(text: "type", kind: .keyword)))
    #expect(typescriptTokens.contains(.init(text: "'hello'", kind: .string)))
  }

  @Test("Code language parses JavaScript and TypeScript aliases")
  func codeLanguageParsesJavaScriptAndTypeScriptAliases() {
    #expect(HarnessCodeLanguage(infoString: "js") == .javascript)
    #expect(HarnessCodeLanguage(infoString: "javascript") == .javascript)
    #expect(HarnessCodeLanguage(infoString: "jsx") == .javascript)
    #expect(HarnessCodeLanguage(infoString: "nodejs") == .javascript)
    #expect(HarnessCodeLanguage(infoString: "ts") == .typescript)
    #expect(HarnessCodeLanguage(infoString: "typescript") == .typescript)
    #expect(HarnessCodeLanguage(infoString: "tsx") == .typescript)
    #expect(HarnessCodeLanguage.javascript.displayName == "JavaScript")
    #expect(HarnessCodeLanguage.typescript.displayName == "TypeScript")
  }

  @Test("Code highlighter handles Vue templates and raw sections")
  func codeHighlighterHandlesVueTemplatesAndRawSections() {
    let templateTokens = HarnessCodeHighlighter.highlight(
      #"<template><Button :label="title">{{ count }}</Button></template>"#,
      language: .vue
    )
    let scriptTokens = HarnessCodeHighlighter.highlight(
      """
      <script setup lang="ts">
      const valid = value < limit
      </script>
      """,
      language: .vue
    )

    #expect(templateTokens.contains(.init(text: "Button", kind: .type)))
    #expect(templateTokens.contains(.init(text: ":label", kind: .property)))
    #expect(templateTokens.contains(.init(text: "{{ count }}", kind: .literal)))
    #expect(scriptTokens.contains(.init(text: "\nconst valid = value < limit\n", kind: .plain)))
  }

  @Test("Code highlighter handles feature files")
  func codeHighlighterHandlesFeatureFiles() {
    let tokens = HarnessCodeHighlighter.highlight(
      """
      @smoke
      Feature: Search
        Scenario Outline: find results
          Given a user is on the page
          * they search for a term
          \"\"\"
          Given this stays plain
          \"\"\"
      """,
      language: .feature
    )

    #expect(tokens.contains(.init(text: "@smoke", kind: .property)))
    #expect(tokens.contains(.init(text: "Feature:", kind: .heading)))
    #expect(tokens.contains(.init(text: "Scenario Outline:", kind: .heading)))
    #expect(tokens.contains(.init(text: "Given", kind: .keyword)))
    #expect(tokens.contains(.init(text: "*", kind: .keyword)))
    #expect(tokens.contains(.init(text: "Given this stays plain", kind: .string)))
  }

  @Test("Code language parses Vue and feature aliases")
  func codeLanguageParsesVueAndFeatureAliases() {
    #expect(HarnessCodeLanguage(infoString: "vue") == .vue)
    #expect(HarnessCodeLanguage(infoString: "feature") == .feature)
    #expect(HarnessCodeLanguage(infoString: "gherkin") == .feature)
    #expect(HarnessCodeLanguage(infoString: "cucumber") == .feature)
    #expect(HarnessCodeLanguage.vue.displayName == "Vue")
    #expect(HarnessCodeLanguage.feature.displayName == "Feature")
  }

  @Test("Code highlighter covers added filetype families")
  func codeHighlighterCoversAddedFiletypeFamilies() {
    let cases: [(HarnessCodeLanguage, String, HarnessCodeToken)] = [
      (.gitignore, "!dist/", .init(text: "!", kind: .operatorSymbol)),
      (.codeowners, "*.swift @ios-team", .init(text: "@ios-team", kind: .property)),
      (.makefile, "build: test", .init(text: "build", kind: .property)),
      (.goModule, "module example.com/app", .init(text: "module", kind: .keyword)),
      (.toml, "[tool.swiftlint]", .init(text: "[tool.swiftlint]", kind: .heading)),
      (.html, #"<div class="app"></div>"#, .init(text: "div", kind: .type)),
      (.dockerfile, "from swift:6.0", .init(text: "from", kind: .keyword)),
      (.template, "{{ .Values.image }}", .init(text: "{{ .Values.image }}", kind: .literal)),
      (.sql, "select * from users", .init(text: "select", kind: .keyword)),
      (.terraform, #"resource "aws_s3_bucket" "logs" {}"#, .init(text: "resource", kind: .keyword)),
      (.stylesheet, "@media screen { color: red; }", .init(text: "media", kind: .keyword)),
      (.ruby, "class Service", .init(text: "class", kind: .keyword)),
      (.config, "[section]", .init(text: "[section]", kind: .heading)),
      (.lua, "local value = true", .init(text: "local", kind: .keyword)),
      (.python, "def run():", .init(text: "def", kind: .keyword)),
      (.powershell, "function Invoke-Thing { }", .init(text: "function", kind: .keyword)),
      (.proto, "message User {}", .init(text: "message", kind: .keyword)),
      (.rego, "package policy", .init(text: "package", kind: .keyword)),
      (.xml, #"<note id="1"/>"#, .init(text: "note", kind: .type)),
    ]
    for (language, source, expectedToken) in cases {
      #expect(
        HarnessCodeHighlighter.highlight(source, language: language).contains(expectedToken)
      )
    }
  }

  @Test("Code language parses added aliases")
  func codeLanguageParsesAddedAliases() {
    #expect(HarnessCodeLanguage(infoString: "gitignore") == .gitignore)
    #expect(HarnessCodeLanguage(infoString: "codeowners") == .codeowners)
    #expect(HarnessCodeLanguage(infoString: "dockerfile") == .dockerfile)
    #expect(HarnessCodeLanguage(infoString: "go.mod") == .goModule)
    #expect(HarnessCodeLanguage(infoString: "toml") == .toml)
    #expect(HarnessCodeLanguage(infoString: "html") == .html)
    #expect(HarnessCodeLanguage(infoString: "sql") == .sql)
    #expect(HarnessCodeLanguage(infoString: "terraform") == .terraform)
    #expect(HarnessCodeLanguage(infoString: "scss") == .stylesheet)
    #expect(HarnessCodeLanguage(infoString: "python") == .python)
    #expect(HarnessCodeLanguage(infoString: "powershell") == .powershell)
    #expect(HarnessCodeLanguage(infoString: "protobuf") == .proto)
    #expect(HarnessCodeLanguage(infoString: "rego") == .rego)
    #expect(HarnessCodeLanguage.goModule.displayName == "Go module")
    #expect(HarnessCodeLanguage.dockerfile.displayName == "Dockerfile")
  }

  @Test("Code highlighter spans cover representative sources without gaps")
  func codeHighlighterSpansCoverRepresentativeSourcesWithoutGaps() {
    let cases: [(HarnessCodeLanguage, String)] = [
      (.swift, "let value = true\nfunc run() { return value }"),
      (.json, #"{"name":"alpha","count":2,"enabled":false}"#),
      (.yaml, "name: alpha\nenabled: true\n# comment"),
      (.codeowners, "*.swift @ios-team # owners"),
      (.feature, "@smoke\nFeature: Search\n  Scenario: find results"),
      (.template, "{{ .Values.service.name }}\n{{/* keep */}}"),
      (.vue, #"<template><Button :label="title">{{ count }}</Button></template>"#),
    ]

    for (language, source) in cases {
      let highlights = HarnessCodeHighlighter.highlightsUncached(source, language: language)
      #expect(highlights.source == source)
      #expect(!highlights.spans.isEmpty)
      let rebuilt = highlights.spans.map { String(highlights.source[$0.range]) }.joined()
      #expect(rebuilt == source)

      for (lhs, rhs) in zip(highlights.spans, highlights.spans.dropFirst()) {
        #expect(lhs.range.upperBound == rhs.range.lowerBound)
        #expect(lhs.kind != rhs.kind)
      }
    }
  }
}
