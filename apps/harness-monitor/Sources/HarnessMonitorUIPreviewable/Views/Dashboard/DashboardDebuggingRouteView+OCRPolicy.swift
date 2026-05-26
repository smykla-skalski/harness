import SwiftUI

enum DashboardOCRSummaryText {
  static func make(
    items: [DashboardOCRImageItem],
    policyState: ClipboardAutomationRuntimeState
  ) -> String {
    guard !items.isEmpty else {
      return "0 images · \(policyState.label)"
    }
    let completed = items.count { item in
      switch item.status {
      case .recognized, .empty, .failed:
        true
      case .pending, .recognizing:
        false
      }
    }
    return "\(completed) of \(items.count) scanned · \(policyState.label)"
  }
}

enum DashboardOCRPasteFeedbackController {
  static func show(
    for items: [DashboardOCRImageItem],
    pasteFeedback: Binding<DashboardOCRPasteFeedback?>,
    highlightedItemIDs: Binding<Set<UUID>>
  ) {
    let itemIDs = Set(items.map(\.id))
    highlightedItemIDs.wrappedValue.formUnion(itemIDs)
    let feedback = DashboardOCRPasteFeedback(count: items.count)
    withAnimation(.bouncy(duration: 0.32, extraBounce: 0.18)) {
      pasteFeedback.wrappedValue = feedback
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_600))
      highlightedItemIDs.wrappedValue.subtract(itemIDs)
      guard pasteFeedback.wrappedValue?.id == feedback.id else {
        return
      }
      withAnimation(.easeOut(duration: 0.18)) {
        pasteFeedback.wrappedValue = nil
      }
    }
  }
}

@MainActor
enum DashboardOCRPolicyDecisionResolver {
  static func decision(
    for source: DashboardOCRIntakeSource,
    policyCenter: AutomationPolicyCenter
  ) -> AutomationPolicyDecision {
    if source == .clipboardPolicy {
      let policy =
        policyCenter.document.policies(for: .clipboard)
        .first { $0.isEnabled && $0.hasAction(.ocrImage) }
        ?? policyCenter.clipboardPolicy
      let isAllowed =
        policyCenter.isAutomationEnabled
        && policy.isEnabled
        && policy.hasAction(.ocrImage)
      return AutomationPolicyDecision(
        policy: policy,
        isAllowed: isAllowed,
        reason: isAllowed ? nil : "\(policy.name) is disabled"
      )
    }
    return policyCenter.decision(
      for: source.policyEventSource,
      contentKinds: [.image]
    )
  }
}

enum DashboardOCRIntakeSource {
  case file
  case drop
  case paste
  case screenshot
  case clipboardPolicy

  var title: String {
    switch self {
    case .file: "File picker OCR"
    case .drop: "Drag and drop OCR"
    case .paste: "Manual paste OCR"
    case .screenshot: "Screenshot folder OCR"
    case .clipboardPolicy: "Clipboard policy OCR"
    }
  }

  var policyEventSource: AutomationPolicyEventSource {
    switch self {
    case .file: .ocrFilePicker
    case .drop: .ocrDrop
    case .paste: .manualOCRPaste
    case .screenshot: .screenshotFolder
    case .clipboardPolicy: .clipboard
    }
  }
}
