import AppKit
import Foundation

struct DashboardOCRPasteboardRequest {
  let id: Int
  let candidates: [DashboardOCRImageCandidate]
  let source: DashboardOCRIntakeSource
  let policyDecision: AutomationPolicyDecision?
}

@MainActor
public enum DashboardDebuggingOCRPasteboardRequests {
  public static let changedNotification = Notification.Name(
    "DashboardDebuggingOCRPasteboardRequests.changed"
  )

  private static var nextRequestID = 0
  private static var pendingRequest: DashboardOCRPasteboardRequest?

  public static func pasteboardContainsImages() -> Bool {
    DashboardOCRInputReader.clipboardContainsImages()
  }

  @discardableResult
  public static func requestPasteFromClipboard() -> Bool {
    requestPaste(fromPasteboard: .general)
  }

  @discardableResult
  static func requestManualPasteFromClipboard(
    policyCenter: AutomationPolicyCenter = .shared
  ) -> Bool {
    let decision = policyCenter.decision(for: .manualOCRPaste, contentKinds: [.image])
    guard manualPasteCanOpenDebugging(decision),
      DashboardOCRInputReader.clipboardContainsImages()
    else {
      return false
    }
    let candidates = DashboardOCRInputReader.candidates(fromPasteboard: .general)
    return requestManualPaste(candidates: candidates, policyDecision: decision)
  }

  @discardableResult
  public static func requestPaste(from providers: [NSItemProvider]) async -> Bool {
    let candidates = await DashboardOCRInputReader.candidates(from: providers)
    return enqueue(candidates)
  }

  @discardableResult
  static func requestPaste(from transferImages: [DashboardOCRTransferImage]) -> Bool {
    let candidates = transferImages.compactMap(\.candidate)
    return enqueue(candidates)
  }

  @discardableResult
  static func requestManualPaste(
    from transferImages: [DashboardOCRTransferImage],
    policyCenter: AutomationPolicyCenter = .shared
  ) -> Bool {
    let candidates = transferImages.compactMap(\.candidate)
    let decision = policyCenter.decision(for: .manualOCRPaste, contentKinds: [.image])
    return requestManualPaste(candidates: candidates, policyDecision: decision)
  }

  @discardableResult
  static func requestPaste(fromPasteboard pasteboard: NSPasteboard) -> Bool {
    let candidates = DashboardOCRInputReader.candidates(fromPasteboard: pasteboard)
    return enqueue(candidates, source: .paste)
  }

  @discardableResult
  static func requestManualPaste(
    candidates: [DashboardOCRImageCandidate],
    policyDecision: AutomationPolicyDecision
  ) -> Bool {
    guard manualPasteCanOpenDebugging(policyDecision) else {
      return false
    }
    let intake = DashboardOCRIntakePolicyEvaluation.evaluate(
      source: .paste,
      decision: policyDecision,
      candidates: candidates
    )
    guard
      intake.shouldProcessImages,
      intake.executionResult?.shouldOpenDashboardDebugging == true
    else {
      return false
    }
    return enqueue(intake.candidates, source: .paste, policyDecision: policyDecision)
  }

  private static func manualPasteCanOpenDebugging(
    _ decision: AutomationPolicyDecision
  ) -> Bool {
    decision.shouldOCRImages && decision.shouldOpenDashboardDebugging
  }

  @discardableResult
  static func requestAutomationClipboard(
    candidates: [DashboardOCRImageCandidate],
    policyDecision: AutomationPolicyDecision
  ) -> Bool {
    enqueue(candidates, source: .clipboardPolicy, policyDecision: policyDecision)
  }

  private static func enqueue(
    _ candidates: [DashboardOCRImageCandidate],
    source: DashboardOCRIntakeSource = .paste,
    policyDecision: AutomationPolicyDecision? = nil
  ) -> Bool {
    let candidatesToQueue = DashboardOCRImageCandidate.mergedByFingerprint(candidates)
    guard !candidatesToQueue.isEmpty else {
      return false
    }
    if let pendingRequest {
      updatePendingRequest(
        pendingRequest,
        candidates: candidatesToQueue,
        source: source,
        policyDecision: policyDecision
      )
      NotificationCenter.default.post(name: changedNotification, object: nil)
      return true
    }
    nextRequestID += 1
    pendingRequest = DashboardOCRPasteboardRequest(
      id: nextRequestID,
      candidates: candidatesToQueue,
      source: source,
      policyDecision: policyDecision
    )
    NotificationCenter.default.post(name: changedNotification, object: nil)
    return true
  }

  private static func updatePendingRequest(
    _ pendingRequest: DashboardOCRPasteboardRequest,
    candidates: [DashboardOCRImageCandidate],
    source: DashboardOCRIntakeSource,
    policyDecision: AutomationPolicyDecision?
  ) {
    self.pendingRequest = DashboardOCRPasteboardRequest(
      id: pendingRequest.id,
      candidates: DashboardOCRImageCandidate.mergedByFingerprint(
        pendingRequest.candidates + candidates
      ),
      source: pendingRequest.source,
      policyDecision: mergedPolicyDecision(
        pendingRequest: pendingRequest,
        source: source,
        policyDecision: policyDecision
      )
    )
  }

  private static func mergedPolicyDecision(
    pendingRequest: DashboardOCRPasteboardRequest,
    source: DashboardOCRIntakeSource,
    policyDecision: AutomationPolicyDecision?
  ) -> AutomationPolicyDecision? {
    guard pendingRequest.source == source else {
      return pendingRequest.policyDecision
    }
    return pendingRequest.policyDecision ?? policyDecision
  }

  static func takePendingRequest(after handledRequestID: Int) -> DashboardOCRPasteboardRequest? {
    guard let request = pendingRequest, request.id > handledRequestID else {
      return nil
    }
    pendingRequest = nil
    return request
  }

  static func resetForTesting() {
    nextRequestID = 0
    pendingRequest = nil
  }
}
