import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Harness Monitor JSON code block")
struct HarnessMonitorJSONCodeBlockTests {
  @Test("Valid JSON is pretty printed with stable key ordering")
  func validJSONIsPrettyPrintedWithStableKeyOrdering() {
    let presentation = HarnessMonitorJSONPresentation.formatted(
      rawJSON: #"{"z":2,"a":"alpha","nested":{"beta":false,"alpha":1}}"#
    )

    #expect(presentation.errorMessage == nil)
    #expect(
      presentation.displayText
        == """
        {
          "a" : "alpha",
          "nested" : {
            "alpha" : 1,
            "beta" : false
          },
          "z" : 2
        }
        """
    )
  }

  @Test("Syntax tokens distinguish keys, strings, numbers, booleans, and null")
  func syntaxTokensDistinguishJSONKinds() {
    let presentation = HarnessMonitorJSONPresentation.formatted(
      rawJSON: #"{"name":"alpha","count":2,"enabled":false,"missing":null}"#
    )

    #expect(presentation.tokens.contains(.init(text: #""name""#, kind: .property)))
    #expect(presentation.tokens.contains(.init(text: #""alpha""#, kind: .string)))
    #expect(presentation.tokens.contains(.init(text: "2", kind: .number)))
    #expect(presentation.tokens.contains(.init(text: "false", kind: .literal)))
    #expect(presentation.tokens.contains(.init(text: "null", kind: .literal)))
  }

  @Test("Invalid JSON shows an error and preserves the raw payload")
  func invalidJSONShowsErrorAndPreservesRawPayload() {
    let rawJSON = #"{"id":"broken","payload":{"agentID":"agent-7"}"#
    let presentation = HarnessMonitorJSONPresentation.formatted(rawJSON: rawJSON)

    #expect(presentation.errorMessage == "Could not format JSON. Showing raw payload")
    #expect(presentation.displayText == rawJSON)
    #expect(presentation.tokens == [.init(text: rawJSON, kind: .plain)])
  }

  @Test("JSONValue formatting keeps unescaped paths readable")
  func jsonValueFormattingKeepsUnescapedPathsReadable() {
    let presentation = HarnessMonitorJSONPresentation.formatted(
      jsonValue: .object([
        "metadata": .object([
          "delivered": .bool(true),
          "path": .string("/tmp/logs/latest.log"),
        ])
      ])
    )

    #expect(presentation.errorMessage == nil)
    #expect(presentation.displayText.contains(#""path" : "/tmp/logs/latest.log""#))
    #expect(!presentation.displayText.contains(#"\/tmp\/logs\/latest.log"#))
  }

  @Test("Audit trail payload presentation reuses the shared JSON formatter")
  func auditTrailPayloadPresentationReusesTheSharedJSONFormatter() {
    let payload = DecisionAuditTrailPayloadPresentation(
      payloadJSON: #"{"message":"Escalate","metadata":{"path":"/tmp/logs/latest.log"}}"#
    )

    #expect(payload.summary == "Escalate")
    guard case .json(let presentation)? = payload.details else {
      Issue.record("Expected structured JSON details")
      return
    }

    #expect(presentation.displayText.contains(#""path" : "/tmp/logs/latest.log""#))
    #expect(!presentation.displayText.contains(#"\/tmp\/logs\/latest.log"#))
  }

  @Test("Audit trail payload presentation preserves invalid payloads as raw text")
  func auditTrailPayloadPresentationPreservesInvalidPayloadsAsRawText() {
    let payload = DecisionAuditTrailPayloadPresentation(
      payloadJSON: #" {"message":"broken" "payload":1} "#
    )

    #expect(payload.summary == nil)
    guard case .raw(let rawPayload)? = payload.details else {
      Issue.record("Expected raw payload fallback")
      return
    }

    #expect(rawPayload == #"{"message":"broken" "payload":1}"#)
  }

  @Test("Card code blocks separate the language header from the body")
  func cardCodeBlocksSeparateTheLanguageHeaderFromTheBody() throws {
    let source = try sourceFile(
      at:
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Shared/HarnessMonitorCodeBlock.swift"
    )

    #expect(source.contains("headerSeparator"))
    #expect(source.contains("header\n      headerSeparator\n      errorMessage\n      codeContent"))
    #expect(source.contains("Divider()"))
    #expect(source.contains("style.colors.border.opacity(borderOpacity)"))
    #expect(source.contains("case .card:"))
    #expect(source.contains("case .plain:"))
  }

  private func sourceFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL = repoRoot.appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
