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
}
