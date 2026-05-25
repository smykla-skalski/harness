import Foundation

@testable import HarnessMonitorKit

private struct ReviewTimelineFetchResult {
  let hook: (@Sendable (String) async -> Void)?
  let response: ReviewsTimelineResponse?
  let error: (any Error)?
}

extension RecordingHarnessClient {
  func configureReviewTimeline(
    pullRequestID: String,
    responses: [ReviewsTimelineResponse]
  ) {
    lock.withLock {
      reviewTimelineResponses[pullRequestID] = responses
    }
  }

  func enqueueReviewTimelineResponse(_ response: ReviewsTimelineResponse) {
    lock.withLock {
      reviewTimelineResponses[response.pullRequestId, default: []].append(response)
    }
  }

  func setReviewTimelineFetchHook(_ hook: @escaping @Sendable (String) async -> Void) {
    lock.withLock {
      reviewTimelineFetchHook = hook
    }
  }

  func configureReviewTimelineError(pullRequestID: String, error: any Error) {
    lock.withLock {
      reviewTimelineErrors[pullRequestID] = error
    }
  }

  func reviewTimelineFetchCount() -> Int {
    lock.withLock { reviewTimelineFetchedRequests.count }
  }

  func reviewTimelineRequestedCursors(for pullRequestID: String) -> [String?] {
    lock.withLock {
      reviewTimelineFetchedRequests
        .filter { $0.pullRequestId == pullRequestID }
        .map(\.cursor)
    }
  }

  func reviewTimelineRequestedPageSizes(for pullRequestID: String) -> [UInt32] {
    lock.withLock {
      reviewTimelineFetchedRequests
        .filter { $0.pullRequestId == pullRequestID }
        .map(\.pageSize)
    }
  }

  func reviewTimelineRequestedForceRefreshValues(for pullRequestID: String) -> [Bool] {
    lock.withLock {
      reviewTimelineFetchedRequests
        .filter { $0.pullRequestId == pullRequestID }
        .map(\.forceRefresh)
    }
  }

  func fetchReviewTimeline(
    request: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    let result = lock.withLock {
      reviewTimelineFetchedRequests.append(request)
      let hook = reviewTimelineFetchHook
      let error = reviewTimelineErrors[request.pullRequestId]
      var queue = reviewTimelineResponses[request.pullRequestId] ?? []
      let next = queue.isEmpty ? nil : queue.removeFirst()
      reviewTimelineResponses[request.pullRequestId] = queue
      return ReviewTimelineFetchResult(hook: hook, response: next, error: error)
    }
    if let hook = result.hook {
      await hook(request.pullRequestId)
    }
    if let error = result.error {
      throw error
    }
    if let queued = result.response {
      return queued
    }
    return ReviewsTimelineResponse(
      pullRequestId: request.pullRequestId,
      entries: [],
      pageInfo: ReviewTimelinePageInfo(),
      viewerCanComment: true,
      fetchedAt: "2026-05-22T00:00:00Z"
    )
  }
}
