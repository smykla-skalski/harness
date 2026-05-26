import AppKit
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard debugging automation policies")
@MainActor
struct DashboardDebuggingAutomationPolicyTests {
  @Test("Automation policies keep clipboard monitoring opt-in")
  func automationPoliciesKeepClipboardMonitoringOptIn() {
    let document = AutomationPolicyDocument()

    #expect(document.isEnabled)
    #expect(document.policy(for: .clipboard).isEnabled == false)
    #expect(document.policy(id: "clipboard.metadata")?.isEnabled == false)
    #expect(document.policy(for: .manualOCRPaste).isEnabled)
    #expect(document.policy(for: .ocrDrop).isEnabled)
    #expect(document.policy(for: .ocrFilePicker).isEnabled)
    #expect(document.policy(for: .screenshotFolder).isEnabled)
  }

  @Test("Clipboard policy filters source applications by bundle id")
  func clipboardPolicyFiltersSourceApplicationsByBundleID() {
    let filter = AutomationSourceAppFilter(
      mode: .allowedOnly,
      allowedBundleIdentifiers: ["com.tinyspeck.slackmacgap"],
      deniedBundleIdentifiers: ["com.example.secret"]
    )

    #expect(
      filter.allows(
        AutomationSourceApplication(
          bundleIdentifier: "com.tinyspeck.slackmacgap",
          localizedName: "Slack",
          processIdentifier: 42
        )
      )
    )
    #expect(
      !filter.allows(
        AutomationSourceApplication(
          bundleIdentifier: "com.apple.Safari",
          localizedName: "Safari",
          processIdentifier: 43
        )
      )
    )
    #expect(
      !filter.allows(
        AutomationSourceApplication(
          bundleIdentifier: "com.example.secret",
          localizedName: "Secret",
          processIdentifier: 44
        )
      )
    )
  }

  @Test("Clipboard policy blocks denied privacy and sensitive markers")
  func clipboardPolicyBlocksDeniedPrivacyAndSensitiveMarkers() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    let document = AutomationPolicyDocument(policies: [policy])
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "DashboardDebuggingAutomationPolicies-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(
      fileURL: directory.appendingPathComponent("policies.json")
    )
    center.setPolicyEnabled(policy.id, isEnabled: true)

    let deniedDecision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      accessBehaviorDescription: "alwaysDeny"
    )
    let sensitiveDecision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      containsSensitiveContent: true,
      accessBehaviorDescription: "alwaysAllow"
    )
    let allowedDecision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      accessBehaviorDescription: "alwaysAllow"
    )

    #expect(document.policy(for: .clipboard).isEnabled)
    #expect(!deniedDecision.isAllowed)
    #expect(!sensitiveDecision.isAllowed)
    #expect(allowedDecision.isAllowed)
  }

  @Test("Clipboard monitoring starts when any clipboard policy is enabled")
  func clipboardMonitoringStartsWhenAnyClipboardPolicyIsEnabled() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(
      fileURL: directory.appendingPathComponent("policies.json")
    )

    #expect(!center.isClipboardMonitorEnabled)

    center.setPolicyEnabled("clipboard.metadata", isEnabled: true)
    #expect(center.isClipboardMonitorEnabled)

    center.setPoliciesEnabled(for: .clipboard, isEnabled: false)
    #expect(!center.isClipboardMonitorEnabled)
  }

  @Test("Custom clipboard policies can match non image content")
  func customClipboardPoliciesCanMatchNonImageContent() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(
      fileURL: directory.appendingPathComponent("policies.json")
    )

    center.createPolicy(for: .clipboard)

    let decision = center.decision(
      for: .clipboard,
      contentKinds: [.text],
      sourceApplication: AutomationSourceApplication(
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        processIdentifier: 100
      ),
      accessBehaviorDescription: "alwaysAllow"
    )

    #expect(decision.isAllowed)
    #expect(decision.policy.id.hasPrefix("policy.clipboard."))
    #expect(decision.shouldRecordMetadata)
    #expect(!decision.shouldOCRImages)
  }

  @Test("Automation event store persists newest bounded events")
  func automationEventStorePersistsNewestBoundedEvents() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AutomationPolicyEventStore(directoryURL: directory, maxItems: 2)

    _ = store.record(event(summary: "first"))
    _ = store.record(event(summary: "second"))
    _ = store.record(event(summary: "third"))

    let events = store.load()

    #expect(events.map(\.summary) == ["third", "second"])
    #expect(store.clear().isEmpty)
    #expect(store.load().isEmpty)
  }

  @Test("Policy execution records metadata actions")
  func policyExecutionRecordsMetadataActions() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    policy.actions = [.recordMetadata]
    let request = executionRequest(
      policy: policy,
      contentKinds: [.text],
      metadata: ClipboardAutomationMetadataPayload(textPreview: "hello", filePaths: [])
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.executedActions == [.recordMetadata])
    #expect(result.skippedActions.isEmpty)
    #expect(result.eventRecord?.textPreview == "hello")
    #expect(result.dispatch?.shouldOpenDashboardDebugging == nil)
  }

  @Test("Policy execution respects audit postprocessor")
  func policyExecutionRespectsAuditPostprocessor() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    policy.actions = [.recordMetadata]
    policy.postprocessors = []
    let request = executionRequest(policy: policy, contentKinds: [.text])

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.executedActions == [.recordMetadata])
    #expect(result.eventRecord == nil)
    #expect(result.executedPostprocessors.isEmpty)
  }

  @Test("Policy execution queues OCR image actions")
  func policyExecutionQueuesOCRImageActions() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    policy.actions = [
      .ocrImage,
      .rememberRecentScan,
      .showFeedback,
      .openDashboardDebugging,
      .recordMetadata,
    ]
    let candidate = imageCandidate()
    let request = executionRequest(
      policy: policy,
      contentKinds: [.image],
      imageCandidates: [candidate]
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.executedActions == policy.actions)
    #expect(result.imageCandidates.count == 1)
    #expect(result.dispatch?.shouldOpenDashboardDebugging == true)
    #expect(result.eventRecord?.executedActions == policy.actions)
  }

  @Test("Policy execution skips OCR when images are unreadable")
  func policyExecutionSkipsOCRWhenImagesAreUnreadable() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    policy.actions = [.ocrImage]
    let request = executionRequest(policy: policy, contentKinds: [.image])

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .skipped)
    #expect(result.reason == "No readable images found")
    #expect(result.skippedActions == [.ocrImage])
    #expect(result.dispatch?.shouldOpenDashboardDebugging == nil)
    #expect(result.eventRecord?.outcome == .skipped)
  }

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
    policy.actions = [.ocrImage, .rememberRecentScan]
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
    #expect(event.executedActions == [.ocrImage])
    #expect(
      event.executedPostprocessors == [
        .sourceSpecificTextCleanup,
        .persistResult,
        .auditEvent,
      ]
    )
    #expect(event.filePaths == ["/tmp/screens/Slack 2026-05-26.png"])
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "DashboardDebuggingAutomationPolicies-\(UUID().uuidString)",
        isDirectory: true
      )
  }

  private func event(summary: String) -> AutomationPolicyEventRecord {
    AutomationPolicyEventRecord(
      source: .clipboard,
      outcome: .matched,
      policyID: "policy",
      policyName: "Policy",
      reason: nil,
      summary: summary,
      contentKinds: [.text],
      declaredTypes: ["public.utf8-plain-text"],
      detectedContentType: nil,
      sourceApplication: nil,
      actions: [.recordMetadata],
      postprocessors: [.auditEvent],
      trigger: "test",
      textPreview: summary
    )
  }

  private func executionRequest(
    policy: AutomationPolicy,
    contentKinds: Set<AutomationClipboardContentKind>,
    metadata: ClipboardAutomationMetadataPayload = .empty,
    imageCandidates: [DashboardOCRImageCandidate] = []
  ) -> AutomationPolicyExecutionRequest {
    AutomationPolicyExecutionRequest(
      source: .clipboard,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "Test payload",
      contentKinds: contentKinds,
      declaredTypes: contentKinds.map(\.rawValue),
      detectedContentType: nil,
      sourceApplication: nil,
      trigger: "test",
      metadata: metadata,
      imageCandidates: imageCandidates
    )
  }

  private func imageCandidate() -> DashboardOCRImageCandidate {
    let image = NSImage(size: NSSize(width: 12, height: 12))
    return DashboardOCRImageCandidate(
      image: image,
      sourceName: "Test image",
      sourceDetail: nil,
      fingerprint: "image"
    )
  }
}
