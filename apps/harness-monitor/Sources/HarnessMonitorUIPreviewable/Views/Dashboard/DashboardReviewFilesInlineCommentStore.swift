import Foundation
import HarnessMonitorKit

extension HarnessMonitorStore {
  @discardableResult
  func postReviewFileComment(
    pullRequestID: String,
    repository: String?,
    draft: DashboardReviewFileCommentDraft,
    body: String,
    viewerLogin _: String?
  ) async -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let client = apiClient else { return false }
    let request = ReviewsFileCommentRequest(
      pullRequestId: pullRequestID,
      repository: repository,
      kind: draft.requestKind,
      body: trimmed,
      path: draft.requestPath,
      line: draft.line.map(UInt32.init),
      side: draft.side?.requestValue,
      threadId: draft.threadID
    )
    do {
      _ = try await client.addReviewFileComment(request: request)
      let response = try await client.fetchReviewTimeline(
        request: ReviewsTimelineRequest(
          pullRequestId: pullRequestID,
          pageSize: 50,
          direction: .older,
          forceRefresh: true
        )
      )
      reviewTimelineViewModel(for: pullRequestID).apply(initial: response)
      return true
    } catch {
      presentFailureFeedback(dashboardReviewsErrorMessage(for: error))
      return false
    }
  }

  @discardableResult
  func postReviewThreadReply(
    pullRequestID: String,
    repository: String?,
    threadID: String,
    body: String,
    viewerLogin _: String?
  ) async -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let client = apiClient else { return false }
    let request = ReviewsFileCommentRequest(
      pullRequestId: pullRequestID,
      repository: repository,
      kind: .reply,
      body: trimmed,
      path: nil,
      line: nil,
      side: nil,
      threadId: threadID
    )
    do {
      _ = try await client.addReviewFileComment(request: request)
      let response = try await client.fetchReviewTimeline(
        request: ReviewsTimelineRequest(
          pullRequestId: pullRequestID,
          pageSize: 50,
          direction: .older,
          forceRefresh: true
        )
      )
      reviewTimelineViewModel(for: pullRequestID).apply(initial: response)
      return true
    } catch {
      presentFailureFeedback(dashboardReviewsErrorMessage(for: error))
      return false
    }
  }
}

extension DashboardReviewFileCommentDraft {
  fileprivate var requestKind: ReviewsFileCommentKind {
    switch kind {
    case .newThread:
      .newThread
    case .reply:
      .reply
    }
  }

  fileprivate var requestPath: String? {
    switch kind {
    case .newThread:
      path
    case .reply:
      nil
    }
  }

  fileprivate var threadID: String? {
    if case .reply(let threadID) = kind {
      return threadID
    }
    return nil
  }
}

extension DashboardReviewFileDiffSide {
  fileprivate var requestValue: String {
    switch self {
    case .old:
      "LEFT"
    case .new:
      "RIGHT"
    }
  }
}
