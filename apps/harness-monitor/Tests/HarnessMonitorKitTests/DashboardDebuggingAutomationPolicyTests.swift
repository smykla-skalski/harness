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
}
