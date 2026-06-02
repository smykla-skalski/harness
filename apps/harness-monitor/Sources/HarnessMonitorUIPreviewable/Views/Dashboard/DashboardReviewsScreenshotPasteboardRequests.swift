import AppKit
import Foundation

struct DashboardReviewsScreenshotPasteboardRequest {
  let id: Int
  let candidates: [DashboardOCRImageCandidate]
}

@MainActor
enum DashboardReviewsScreenshotPasteboardRequests {
  static let changedNotification = Notification.Name(
    "DashboardReviewsScreenshotPasteboardRequests.changed"
  )

  private static var nextRequestID = 0
  private static var pendingRequest: DashboardReviewsScreenshotPasteboardRequest?

  @discardableResult
  static func requestPasteFromClipboard() -> Bool {
    requestPaste(fromPasteboard: .general)
  }

  @discardableResult
  static func requestPaste(from transferImages: [DashboardOCRTransferImage]) -> Bool {
    enqueue(transferImages.compactMap(\.candidate))
  }

  @discardableResult
  static func requestPaste(fromPasteboard pasteboard: NSPasteboard) -> Bool {
    enqueue(DashboardOCRInputReader.candidates(fromPasteboard: pasteboard))
  }

  private static func enqueue(_ candidates: [DashboardOCRImageCandidate]) -> Bool {
    let candidatesToQueue = DashboardOCRImageCandidate.mergedByFingerprint(candidates)
    guard !candidatesToQueue.isEmpty else { return false }
    if let pendingRequest {
      self.pendingRequest = DashboardReviewsScreenshotPasteboardRequest(
        id: pendingRequest.id,
        candidates: DashboardOCRImageCandidate.mergedByFingerprint(
          pendingRequest.candidates + candidatesToQueue
        )
      )
      NotificationCenter.default.post(name: changedNotification, object: nil)
      return true
    }
    nextRequestID += 1
    pendingRequest = DashboardReviewsScreenshotPasteboardRequest(
      id: nextRequestID,
      candidates: candidatesToQueue
    )
    NotificationCenter.default.post(name: changedNotification, object: nil)
    return true
  }

  static func takePendingRequest(
    after handledRequestID: Int
  ) -> DashboardReviewsScreenshotPasteboardRequest? {
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
