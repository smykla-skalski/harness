import AppKit
import Foundation

struct DashboardReviewsTextPasteboardRequest: Equatable {
  let id: Int
  let text: String
}

@MainActor
enum DashboardReviewsTextPasteboardRequests {
  static let changedNotification = Notification.Name(
    "DashboardReviewsTextPasteboardRequests.changed"
  )

  private static var nextRequestID = 0
  private static var pendingRequest: DashboardReviewsTextPasteboardRequest?

  @discardableResult
  static func requestPasteFromClipboard() -> Bool {
    requestPaste(fromPasteboard: .general)
  }

  @discardableResult
  static func requestPaste(fromPasteboard pasteboard: NSPasteboard) -> Bool {
    requestPaste(
      pasteboard.string(forType: .string)
        ?? pasteboard.string(forType: NSPasteboard.PasteboardType.URL)
    )
  }

  @discardableResult
  static func requestPaste(_ text: String?) -> Bool {
    guard
      let text = normalizedPasteText(text),
      !GitHubPullRequestReferenceParser.references(in: text).isEmpty
    else {
      return false
    }
    return enqueue(text)
  }

  @discardableResult
  static func requestPaste(_ items: [DashboardReviewsTextPasteTransferItem]) -> Bool {
    requestPaste(items.map(\.text).joined(separator: "\n"))
  }

  static func takePendingRequest(
    after handledRequestID: Int
  ) -> DashboardReviewsTextPasteboardRequest? {
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

  private static func normalizedPasteText(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func enqueue(_ text: String) -> Bool {
    if let pendingRequest {
      self.pendingRequest = DashboardReviewsTextPasteboardRequest(
        id: pendingRequest.id,
        text: [pendingRequest.text, text].joined(separator: "\n")
      )
      NotificationCenter.default.post(name: changedNotification, object: nil)
      return true
    }
    nextRequestID += 1
    pendingRequest = DashboardReviewsTextPasteboardRequest(id: nextRequestID, text: text)
    NotificationCenter.default.post(name: changedNotification, object: nil)
    return true
  }
}
