import AppKit
import Foundation

struct ClipboardAutomationMetadataPayload: Equatable {
  var textPreview: String?
  var filePaths: [String]

  static let empty = Self(textPreview: nil, filePaths: [])
}

extension ClipboardAutomationSnapshot {
  func eventRecord(
    decision: AutomationPolicyDecision,
    outcome: AutomationPolicyEventOutcome,
    reason: String?,
    metadata: ClipboardAutomationMetadataPayload = .empty
  ) -> AutomationPolicyEventRecord {
    AutomationPolicyEventRecord(
      source: .clipboard,
      outcome: outcome,
      policyID: decision.policy.id,
      policyName: decision.policy.name,
      reason: reason,
      summary: summary,
      contentKinds: contentKinds,
      declaredTypes: declaredTypes,
      detectedContentType: detectedContentType,
      sourceApplication: sourceApplication,
      actions: decision.policy.actions,
      postprocessors: decision.policy.postprocessors,
      trigger: triggerDescription,
      textPreview: metadata.textPreview,
      filePaths: metadata.filePaths
    )
  }

  func deniedOutcome(for decision: AutomationPolicyDecision) -> AutomationPolicyEventOutcome {
    let reason = decision.reason?.lowercased() ?? ""
    return reason.contains("denied") ? .denied : .skipped
  }

  func readableMetadata(
    from pasteboard: NSPasteboard,
    shouldRead: Bool
  ) -> ClipboardAutomationMetadataPayload {
    guard shouldRead else {
      return .empty
    }
    return ClipboardAutomationMetadataPayload(
      textPreview: textPreview(from: pasteboard),
      filePaths: filePaths(from: pasteboard)
    )
  }

  private var triggerDescription: String {
    switch reason {
    case .manualCapture:
      "Manual menu-bar capture"
    case .poll(let changeCount):
      "NSPasteboard.general.changeCount \(changeCount)"
    }
  }

  private func textPreview(from pasteboard: NSPasteboard) -> String? {
    let text =
      pasteboard.string(forType: .string)
      ?? pasteboard.string(forType: NSPasteboard.PasteboardType.URL)
    guard let text, !text.isEmpty else {
      return nil
    }
    return String(text.prefix(1_000))
  }

  private func filePaths(from pasteboard: NSPasteboard) -> [String] {
    let urls =
      pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: nil
      ) as? [URL] ?? []
    var seen = Set<String>()
    return urls.compactMap { url -> String? in
      guard url.isFileURL else {
        return nil
      }
      let path = url.path
      return seen.insert(path).inserted ? path : nil
    }
  }
}
