import AppKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard debugging OCR intake policy")
@MainActor
struct DashboardDebuggingOCRIntakePolicyTests {
  @Test("User-originated OCR intake audits unreadable images with partial execution")
  func userOriginatedOCRIntakeAuditsUnreadableImagesWithPartialExecution() throws {
    let evaluation = DashboardOCRIntakePolicyEvaluation.evaluate(
      source: .drop,
      decision: AutomationPolicyDecision(
        policy: AutomationPolicyDocument.defaultPolicy(for: .ocrDrop),
        isAllowed: true,
        reason: nil
      ),
      candidates: []
    )
    let event = try #require(evaluation.executionResult?.eventRecord)

    #expect(!evaluation.shouldProcessImages)
    #expect(evaluation.failureMessage == "No readable images found")
    #expect(event.source == .ocrDrop)
    #expect(event.outcome == .matched)
    #expect(event.executedActions == [.recordMetadata])
    #expect(event.skippedActions == [.ocrImage, .rememberRecentScan])
    #expect(event.executedPostprocessors == [.auditEvent])
  }

  @Test("User-originated OCR intake records denied policy decisions")
  func userOriginatedOCRIntakeRecordsDeniedPolicyDecisions() throws {
    let policy = AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste)
    let evaluation = DashboardOCRIntakePolicyEvaluation.evaluate(
      source: .paste,
      decision: AutomationPolicyDecision(
        policy: policy,
        isAllowed: false,
        reason: "Manual paste policy disabled"
      ),
      candidates: [imageCandidate()]
    )
    let event = try #require(evaluation.executionResult?.eventRecord)

    #expect(!evaluation.shouldProcessImages)
    #expect(evaluation.failureMessage == "Manual paste policy disabled")
    #expect(event.source == .manualOCRPaste)
    #expect(event.outcome == .skipped)
    #expect(event.reason == "Manual paste policy disabled")
    #expect(event.skippedActions == policy.actions)
  }

  @Test("Clipboard policy intake reuses prior monitor evaluation")
  func clipboardPolicyIntakeReusesPriorMonitorEvaluation() {
    let evaluation = DashboardOCRIntakePolicyEvaluation.evaluate(
      source: .clipboardPolicy,
      decision: AutomationPolicyDecision(
        policy: AutomationPolicyDocument.defaultPolicy(for: .clipboard),
        isAllowed: true,
        reason: nil
      ),
      candidates: [imageCandidate()]
    )

    #expect(evaluation.shouldProcessImages)
    #expect(evaluation.executionResult == nil)
  }

  @Test("Clipboard policy OCR preserves the matched policy decision through queued intake")
  func clipboardPolicyOCRPreservesMatchedPolicyDecisionThroughQueuedIntake() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    let policy = AutomationPolicy(
      id: "synthetic.clipboard.ocr",
      name: "Synthetic Clipboard OCR",
      eventSource: .clipboard,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint],
      actions: [.ocrImage, .rememberRecentScan],
      postprocessors: [.persistResult]
    )
    let decision = AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)

    let didQueue = DashboardDebuggingOCRPasteboardRequests.requestAutomationClipboard(
      candidates: [imageCandidate()],
      policyDecision: decision
    )
    let request = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )
    let resolvedDecision = DashboardOCRPolicyDecisionResolver.decision(
      for: request.source,
      policyCenter: AutomationPolicyCenter(
        fileURL: temporaryDirectory().appendingPathComponent("policies.json")
      ),
      providedDecision: request.policyDecision
    )

    #expect(didQueue)
    #expect(request.source == .clipboardPolicy)
    #expect(request.policyDecision == decision)
    #expect(resolvedDecision == decision)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "DashboardDebuggingOCRIntakePolicy-\(UUID().uuidString)",
        isDirectory: true
      )
  }

  private func imageCandidate() -> DashboardOCRImageCandidate {
    DashboardOCRImageCandidate(
      image: NSImage(size: NSSize(width: 12, height: 12)),
      sourceName: "Synthetic screenshot.png",
      sourceDetail: nil,
      fingerprint: "synthetic-image"
    )
  }
}
