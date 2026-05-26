import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMarkdownParserTests {
  private func codeBlock(
    parsing markdown: String
  ) -> (HarnessCodeLanguage, HarnessCodeHighlights)? {
    let document = HarnessMarkdownParser.parse(markdown)
    guard case .codeBlock(let language, let highlights)? = document.blocks.first else { return nil }
    return (language, highlights)
  }

  @Test("Bare fence with a shell prompt infers the shell language and highlights it")
  func bareFenceShellPromptInfersShell() {
    guard
      let (language, highlights) = codeBlock(
        parsing: """
          ```
          $ kubectl -n kuma-system get rs
          NAME                            DESIRED
          ```
          """)
    else {
      Issue.record("Expected a code block")
      return
    }
    #expect(language == .shell)
    #expect(language.displayName == "Shell")
    // Generic highlighting would collapse the whole source into one .plain span,
    // so a standalone prompt token proves the shell highlighter actually ran.
    #expect(highlights.contains(.init(text: "$", kind: .literal)))
  }

  @Test("Bare fence whose first word is a known command infers shell")
  func bareFenceKnownCommandInfersShell() {
    guard
      let (language, _) = codeBlock(
        parsing: """
          ```
          kubectl get pods -A
          ```
          """)
    else {
      Issue.record("Expected a code block")
      return
    }
    #expect(language == .shell)
  }

  @Test("Bare fence with a JSON object infers the JSON language")
  func bareFenceJSONInfersJSON() {
    guard
      let (language, highlights) = codeBlock(
        parsing: """
          ```
          {"name": "alpha", "count": 2, "enabled": false}
          ```
          """)
    else {
      Issue.record("Expected a code block")
      return
    }
    #expect(language == .json)
    #expect(language.displayName == "JSON")
    #expect(highlights.contains(.init(text: "\"name\"", kind: .property)))
  }

  @Test("Bare fence with a unified diff infers the diff language")
  func bareFenceDiffInfersDiff() {
    guard
      let (language, _) = codeBlock(
        parsing: """
          ```
          diff --git a/main.swift b/main.swift
          @@ -1,2 +1,2 @@
          -let value = false
          +let value = true
          ```
          """)
    else {
      Issue.record("Expected a code block")
      return
    }
    #expect(language == .diff)
    #expect(language.displayName == "Diff")
  }

  @Test("Bare fence with plain prose stays generic")
  func bareFencePlainProseStaysGeneric() {
    guard
      let (language, _) = codeBlock(
        parsing: """
          ```
          This deployment created a new ReplicaSet that could not place pods.
          ```
          """)
    else {
      Issue.record("Expected a code block")
      return
    }
    #expect(language == .generic)
    #expect(language.displayName == nil)
  }

  @Test("An explicit unrecognized tag is respected as generic without sniffing")
  func explicitUnknownTagStaysGeneric() {
    guard
      let (language, _) = codeBlock(
        parsing: """
          ```text
          $ kubectl get pods
          ```
          """)
    else {
      Issue.record("Expected a code block")
      return
    }
    #expect(language == .generic)
  }

  @Test("An explicit recognized tag wins over the content shape")
  func explicitTagWinsOverContent() {
    guard
      let (language, _) = codeBlock(
        parsing: """
          ```yaml
          $ kubectl get pods
          ```
          """)
    else {
      Issue.record("Expected a code block")
      return
    }
    #expect(language == .yaml)
  }

  @Test("Content inference returns the high-confidence shapes and nil otherwise")
  func contentInferenceMatrix() {
    #expect(HarnessCodeLanguage.inferredFromContent("$ ls -la") == .shell)
    #expect(HarnessCodeLanguage.inferredFromContent("kubectl get pods") == .shell)
    #expect(HarnessCodeLanguage.inferredFromContent(#"{"a": 1}"#) == .json)
    #expect(HarnessCodeLanguage.inferredFromContent("[1, 2, \"three\"]") == .json)
    #expect(HarnessCodeLanguage.inferredFromContent("@@ -1 +1 @@\n-a\n+b") == .diff)
    #expect(HarnessCodeLanguage.inferredFromContent("just some prose words") == nil)
    #expect(HarnessCodeLanguage.inferredFromContent("") == nil)
  }

  @Test("Content inference uses index scanning instead of line array allocation")
  func contentInferenceUsesIndexScanningInsteadOfLineArrayAllocation() throws {
    let source = try markdownSupportSource(named: "HarnessCodeLanguageInference.swift")
    #expect(source.contains("private struct CodeFenceLanguageInterpreter"))
    #expect(source.contains("source[lineStart..<contentRange.upperBound].firstIndex(of: \"\\n\")"))
    #expect(!source.contains(".trimmingCharacters(in: .whitespacesAndNewlines)"))
    #expect(
      !source.contains(
        ".split(separator: \"\\n\", omittingEmptySubsequences: false).map(String.init)"
      )
    )
  }

  private func markdownSupportSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      appRoot
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable/Support/Markdown")
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
