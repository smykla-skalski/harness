import AppKit
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension DashboardDebuggingAutomationPolicyTests {
  @Test("OCR recognition policy only cleans up text when postprocessor is enabled")
  func ocrRecognitionPolicyOnlyCleansUpTextWhenPostprocessorIsEnabled() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste)
    policy.postprocessors = [.persistResult, .auditEvent]
    let rawText = "• https: //example. invalid/acme/widget/pull/9801 /files"
    let sourceMetadata = [
      DashboardOCRImageSourceMetadata(
        name: "Slack 2026-05-26 14.09.28.png",
        detail: "/tmp/screens"
      )
    ]

    let unprocessedPolicy = DashboardOCRRecognitionPolicy(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
    )

    #expect(
      unprocessedPolicy.displayText(
        from: rawText,
        sourceMetadata: sourceMetadata
      ) == rawText
    )

    policy.postprocessors = [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    let processedPolicy = DashboardOCRRecognitionPolicy(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
    )

    #expect(
      processedPolicy.displayText(
        from: rawText,
        sourceMetadata: sourceMetadata
      ) == "• https://example.invalid/acme/widget/pull/9801/files"
    )
  }

  @Test("OCR recognition policy requires action and postprocessor before persisting recents")
  func ocrRecognitionPolicyRequiresActionAndPostprocessorBeforePersistingRecents() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste)
    policy.actions = [.ocrImage, .rememberRecentScan]
    policy.postprocessors = [.sourceSpecificTextCleanup, .auditEvent]

    let missingPostprocessor = DashboardOCRRecognitionPolicy(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
    )

    #expect(!missingPostprocessor.shouldPersistRecentScan)

    policy.actions = [.ocrImage]
    policy.postprocessors = [.persistResult]
    let missingAction = DashboardOCRRecognitionPolicy(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
    )

    #expect(!missingAction.shouldPersistRecentScan)

    policy.actions = [.ocrImage, .rememberRecentScan]
    let persistentPolicy = DashboardOCRRecognitionPolicy(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
    )

    #expect(persistentPolicy.shouldPersistRecentScan)
  }

  @Test("OCR recognition policy audits scanned text with executed postprocessors")
  func ocrRecognitionPolicyAuditsScannedTextWithExecutedPostprocessors() throws {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste)
    policy.actions = [.ocrImage, .rememberRecentScan, .recordMetadata]
    policy.postprocessors = [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    let recognitionPolicy = DashboardOCRRecognitionPolicy(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
    )
    var item = DashboardOCRImageItem(
      candidate: DashboardOCRImageCandidate(
        image: imageCandidate().image,
        sourceName: "Slack 2026-05-26.png",
        sourceDetail: "/tmp/screens",
        fingerprint: "slack"
      )
    )
    let rawText = "• https: //example. invalid/acme/widget/pull/9801 /files"
    item.recognizedText = recognitionPolicy.displayText(
      from: rawText,
      sourceMetadata: item.sourceMetadata
    )

    let event = try #require(
      recognitionPolicy.eventRecord(
        for: item,
        result: .success(rawText),
        didPersistRecentScan: true
      )
    )

    #expect(event.source == .manualOCRPaste)
    #expect(event.outcome == .matched)
    #expect(event.textPreview == "• https://example.invalid/acme/widget/pull/9801/files")
    #expect(event.executedActions == [.ocrImage, .rememberRecentScan, .recordMetadata])
    #expect(
      event.executedPostprocessors == [
        .sourceSpecificTextCleanup,
        .persistResult,
        .auditEvent,
      ]
    )
    #expect(event.filePaths == ["/tmp/screens/Slack 2026-05-26.png"])
  }
}
