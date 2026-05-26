import AppKit
import Foundation

@MainActor
enum ClipboardAutomationBackgroundOCRProcessor {
  typealias Recognize = (NSImage) async -> DashboardOCRRecognitionResult

  static func process(
    _ dispatch: ClipboardAutomationDispatch,
    center: AutomationPolicyCenter,
    recentStore: DashboardOCRRecentImageStore = .shared,
    recognize: @escaping Recognize = DashboardOCRRecognizer.recognizeText(in:)
  ) async {
    guard dispatch.policyDecision.shouldOCRImages, !dispatch.candidates.isEmpty else {
      return
    }
    let recognitionPolicy = DashboardOCRRecognitionPolicy(
      source: .clipboardPolicy,
      decision: dispatch.policyDecision
    )
    let context = Context(
      recognitionPolicy: recognitionPolicy,
      sourceApplication: dispatch.sourceApplication,
      center: center,
      recentStore: recentStore
    )
    for candidate in dispatch.candidates {
      await process(candidate, context: context, recognize: recognize)
    }
  }

  private static func process(
    _ candidate: DashboardOCRImageCandidate,
    context: Context,
    recognize: Recognize
  ) async {
    var item = DashboardOCRImageItem(candidate: candidate)
    item.status = .recognizing
    let result = await recognize(item.image)
    if let errorMessage = result.errorMessage {
      item.status = .failed(errorMessage)
      item.recognizedText = ""
    } else {
      let text = context.recognitionPolicy.displayText(
        from: result.text,
        sourceMetadata: item.sourceMetadata
      )
      item.recognizedText = text
      item.status = text.isEmpty ? .empty : .recognized
    }
    let didPersistRecentScan = persist(
      item,
      using: context.recognitionPolicy,
      recentStore: context.recentStore
    )
    if let event = context.recognitionPolicy.eventRecord(
      for: item,
      result: result,
      didPersistRecentScan: didPersistRecentScan,
      sourceApplication: context.sourceApplication,
      trigger: "Clipboard policy background recognition"
    ) {
      context.center.recordAutomationEvent(event)
    }
  }

  private static func persist(
    _ item: DashboardOCRImageItem,
    using policy: DashboardOCRRecognitionPolicy,
    recentStore: DashboardOCRRecentImageStore
  ) -> Bool {
    guard policy.shouldPersistRecentScan else {
      return false
    }
    _ = recentStore.record([item])
    return true
  }

  private struct Context {
    let recognitionPolicy: DashboardOCRRecognitionPolicy
    let sourceApplication: AutomationSourceApplication?
    let center: AutomationPolicyCenter
    let recentStore: DashboardOCRRecentImageStore
  }
}
