import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMarkdownParserTests {
  private struct HighlighterCase {
    var language: HarnessCodeLanguage
    var source: String
    var expectedToken: HarnessCodeToken
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
    let cases: [HighlighterCase] = [
      .init(
        language: .gitignore, source: "!dist/",
        expectedToken: .init(text: "!", kind: .operatorSymbol)),
      .init(
        language: .codeowners, source: "*.swift @ios-team",
        expectedToken: .init(text: "@ios-team", kind: .property)),
      .init(
        language: .makefile, source: "build: test",
        expectedToken: .init(text: "build", kind: .property)),
      .init(
        language: .goModule, source: "module example.com/app",
        expectedToken: .init(text: "module", kind: .keyword)),
      .init(
        language: .toml, source: "[tool.swiftlint]",
        expectedToken: .init(text: "[tool.swiftlint]", kind: .heading)),
      .init(
        language: .html, source: #"<div class="app"></div>"#,
        expectedToken: .init(text: "div", kind: .type)),
      .init(
        language: .dockerfile, source: "from swift:6.0",
        expectedToken: .init(text: "from", kind: .keyword)),
      .init(
        language: .template, source: "{{ .Values.image }}",
        expectedToken: .init(text: "{{ .Values.image }}", kind: .literal)),
      .init(
        language: .sql, source: "select * from users",
        expectedToken: .init(text: "select", kind: .keyword)),
      .init(
        language: .terraform, source: #"resource "aws_s3_bucket" "logs" {}"#,
        expectedToken: .init(text: "resource", kind: .keyword)),
      .init(
        language: .stylesheet, source: "@media screen { color: red; }",
        expectedToken: .init(text: "media", kind: .keyword)),
      .init(
        language: .ruby, source: "class Service",
        expectedToken: .init(text: "class", kind: .keyword)),
      .init(
        language: .config, source: "[section]",
        expectedToken: .init(text: "[section]", kind: .heading)),
      .init(
        language: .lua, source: "local value = true",
        expectedToken: .init(text: "local", kind: .keyword)),
      .init(
        language: .python, source: "def run():",
        expectedToken: .init(text: "def", kind: .keyword)),
      .init(
        language: .powershell, source: "function Invoke-Thing { }",
        expectedToken: .init(text: "function", kind: .keyword)),
      .init(
        language: .proto, source: "message User {}",
        expectedToken: .init(text: "message", kind: .keyword)),
      .init(
        language: .rego, source: "package policy",
        expectedToken: .init(text: "package", kind: .keyword)),
      .init(
        language: .xml, source: #"<note id="1"/>"#,
        expectedToken: .init(text: "note", kind: .type)),
    ]
    for item in cases {
      #expect(
        HarnessCodeHighlighter.highlight(item.source, language: item.language)
          .contains(item.expectedToken)
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
