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

struct DashboardOCRRecognitionPolicy: Sendable {
  let source: DashboardOCRIntakeSource
  let decision: AutomationPolicyDecision

  var shouldPersistRecentScan: Bool {
    decision.shouldRememberRecentScan && decision.shouldPersistResult
  }

  var shouldApplyTextCleanup: Bool {
    decision.shouldApplySourceSpecificTextCleanup
  }

  var ocrConfiguration: AutomationPolicyOCRConfiguration {
    decision.policy.ocrConfiguration ?? AutomationPolicyOCRConfiguration()
  }

  func displayText(
    from rawText: String,
    sourceMetadata: [DashboardOCRImageSourceMetadata]
  ) -> String {
    let text =
      shouldApplyTextCleanup
      ? DashboardOCRTextPostProcessor.process(
        rawText,
        sourceMetadata: sourceMetadata
      ).displayText
      : rawText
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func eventRecord(
    for item: DashboardOCRImageItem,
    result: DashboardOCRRecognitionResult,
    didPersistRecentScan: Bool,
    sourceApplication: AutomationSourceApplication? = nil,
    trigger: String? = nil
  ) -> AutomationPolicyEventRecord? {
    guard decision.shouldAuditEvent else {
      return nil
    }
    let didSucceed = result.errorMessage == nil
    let textPreview = item.recognizedText.isEmpty ? nil : String(item.recognizedText.prefix(1_000))
    return AutomationPolicyEventRecord(
      source: source.policyEventSource,
      outcome: didSucceed ? .matched : .failed,
      policyID: decision.policy.id,
      policyName: decision.policy.name,
      reason: result.errorMessage,
      summary: summary(for: item, didSucceed: didSucceed),
      contentKinds: [.image],
      declaredTypes: [AutomationClipboardContentKind.image.rawValue],
      detectedContentType: AutomationClipboardContentKind.image.rawValue,
      sourceApplication: sourceApplication,
      actions: decision.policy.executionActions,
      postprocessors: decision.policy.postprocessors,
      executedActions: executedActions(
        didSucceed: didSucceed,
        didPersistRecentScan: didPersistRecentScan
      ),
      skippedActions: skippedActions(didSucceed: didSucceed),
      executedPostprocessors: executedPostprocessors(
        didSucceed: didSucceed,
        didPersistRecentScan: didPersistRecentScan
      ),
      trigger: trigger ?? "\(source.title) recognition",
      textPreview: textPreview,
      filePaths: item.sourceMetadata.copyableFilePaths
    )
  }

  private func executedActions(
    didSucceed: Bool,
    didPersistRecentScan: Bool
  ) -> [AutomationPolicyAction] {
    var actions: [AutomationPolicyAction] = []
    if didSucceed && decision.shouldOCRImages {
      actions.append(.ocrImage)
    }
    if didPersistRecentScan {
      actions.append(.rememberRecentScan)
    }
    if decision.shouldRecordMetadata {
      actions.append(.recordMetadata)
    }
    return actions
  }

  private func skippedActions(didSucceed: Bool) -> [AutomationPolicyAction] {
    didSucceed || !decision.policy.hasAction(.ocrImage) ? [] : [.ocrImage]
  }

  private func executedPostprocessors(
    didSucceed: Bool,
    didPersistRecentScan: Bool
  ) -> [AutomationPolicyPostprocessor] {
    var postprocessors: [AutomationPolicyPostprocessor] = []
    if didSucceed && shouldApplyTextCleanup {
      postprocessors.append(.sourceSpecificTextCleanup)
    }
    if didPersistRecentScan {
      postprocessors.append(.persistResult)
    }
    postprocessors.append(.auditEvent)
    return postprocessors
  }

  private func summary(for item: DashboardOCRImageItem, didSucceed: Bool) -> String {
    guard didSucceed else {
      return "OCR failed: \(item.sourceName)"
    }
    if item.recognizedText.isEmpty {
      return "OCR scanned no text: \(item.sourceName)"
    }
    return "OCR scanned text: \(item.sourceName)"
  }
}

struct DashboardOCRIntakePolicyEvaluation {
  let source: DashboardOCRIntakeSource
  let decision: AutomationPolicyDecision
  let candidates: [DashboardOCRImageCandidate]
  let executionResult: AutomationPolicyExecutionResult?

  var shouldProcessImages: Bool {
    guard !candidates.isEmpty else {
      return false
    }
    if source == .clipboardPolicy {
      return decision.shouldOCRImages
    }
    return executionResult?.executedActions.contains(.ocrImage) == true
  }

  var failureMessage: String {
    if !decision.shouldOCRImages {
      return decision.reason ?? "\(source.title) is disabled by policy"
    }
    return executionResult?.reason ?? "No readable images found"
  }

  static func evaluate(
    source: DashboardOCRIntakeSource,
    decision: AutomationPolicyDecision,
    candidates: [DashboardOCRImageCandidate]
  ) -> Self {
    let mergedCandidates =
      decision.policy.hasPreprocessor(.dedupeByFingerprint)
      ? DashboardOCRImageCandidate.mergedByFingerprint(candidates)
      : candidates
    guard source != .clipboardPolicy else {
      return Self(
        source: source,
        decision: decision,
        candidates: mergedCandidates,
        executionResult: nil
      )
    }
    let request = AutomationPolicyExecutionRequest(
      source: source.policyEventSource,
      decision: decision,
      summary: summary(source: source, candidateCount: mergedCandidates.count),
      contentKinds: [.image],
      declaredTypes: [AutomationClipboardContentKind.image.rawValue],
      detectedContentType: AutomationClipboardContentKind.image.rawValue,
      sourceApplication: nil,
      trigger: "\(source.title) intake",
      metadata: .empty,
      imageCandidates: mergedCandidates
    )
    return Self(
      source: source,
      decision: decision,
      candidates: mergedCandidates,
      executionResult: AutomationPolicyExecutionPipeline.execute(request)
    )
  }

  @MainActor
  func recordEvent(in policyCenter: AutomationPolicyCenter) {
    guard let eventRecord = executionResult?.eventRecord else {
      return
    }
    policyCenter.recordAutomationEvent(eventRecord)
  }

  private static func summary(
    source: DashboardOCRIntakeSource,
    candidateCount: Int
  ) -> String {
    guard candidateCount > 0 else {
      return "\(source.title): no readable images"
    }
    return
      "\(source.title): \(candidateCount) readable \(candidateCount == 1 ? "image" : "images")"
  }
}

@MainActor
enum DashboardOCRPolicyDecisionResolver {
  static func decision(
    for source: DashboardOCRIntakeSource,
    policyCenter: AutomationPolicyCenter,
    providedDecision: AutomationPolicyDecision? = nil
  ) -> AutomationPolicyDecision {
    if source == .clipboardPolicy, let providedDecision {
      return providedDecision
    }
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

enum DashboardOCRIntakeSource: Sendable {
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
