import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func configureReviewBody(
    pullRequestID: String,
    body: String,
    prUpdatedAt: String = "2026-05-21T00:00:00Z",
    fetchedAt: String = "2026-05-21T00:00:00Z"
  ) {
    lock.withLock {
      reviewBodyResponses[pullRequestID] = ReviewsBodyResponse(
        pullRequestID: pullRequestID,
        body: body,
        prUpdatedAt: prUpdatedAt,
        fetchedAt: fetchedAt,
        fromCache: false
      )
    }
  }

  /// Closure runs inside `fetchReviewBody` before the response
  /// resolves; lets tests suspend the first fetch so a concurrent caller
  /// can observe in-flight dedupe.
  func setReviewBodyFetchHook(_ hook: @escaping @Sendable (String) async -> Void) {
    lock.withLock {
      reviewBodyFetchHook = hook
    }
  }

  func reviewBodyFetchCount() -> Int {
    lock.withLock { reviewBodyFetchedIDs.count }
  }

  func fetchReviewBody(
    request: ReviewsBodyRequest
  ) async throws -> ReviewsBodyResponse {
    let (hook, response):
      (
        (@Sendable (String) async -> Void)?, ReviewsBodyResponse?
      ) = lock.withLock {
        reviewBodyFetchedIDs.append(request.pullRequestID)
        return (reviewBodyFetchHook, reviewBodyResponses[request.pullRequestID])
      }
    if let hook {
      await hook(request.pullRequestID)
    }
    if let response {
      return response
    }
    return ReviewsBodyResponse(
      pullRequestID: request.pullRequestID,
      body: "",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z",
      fromCache: false
    )
  }

  func configureReviewBodyUpdate(
    pullRequestID: String,
    outcome: ReviewsBodyUpdateOutcome,
    currentBody: String,
    currentBodySHA256: String = "",
    prUpdatedAt: String = "2026-05-21T00:00:00Z",
    fetchedAt: String = "2026-05-21T00:00:00Z"
  ) {
    lock.withLock {
      reviewBodyUpdateOutcomes[pullRequestID] = ReviewsBodyUpdateResponse(
        pullRequestID: pullRequestID,
        outcome: outcome,
        currentBody: currentBody,
        currentBodySHA256: currentBodySHA256,
        prUpdatedAt: prUpdatedAt,
        fetchedAt: fetchedAt
      )
    }
  }

  func configureReviewBodyUpdateError(pullRequestID: String, error: any Error) {
    lock.withLock {
      reviewBodyUpdateErrors[pullRequestID] = error
    }
  }

  func configureReviewCommentResponse(_ response: ReviewsActionResponse) {
    lock.withLock {
      reviewCommentResponse = response
    }
  }

  func configureReviewCommentError(_ error: any Error) {
    lock.withLock {
      reviewCommentError = error
    }
  }

  func configureReviewPreviewDelay(_ delay: Duration?) {
    lock.withLock {
      reviewPreviewDelay = delay
    }
  }

  func recordedReviewPreviewRequests() -> [ReviewsFilesPreviewRequest] {
    lock.withLock { reviewPreviewRequests }
  }

  func configureReviewPatchDelay(_ delay: Duration?) {
    lock.withLock {
      reviewPatchDelay = delay
    }
  }

  func recordedReviewPatchRequests() -> [ReviewsFilesPatchRequest] {
    lock.withLock { reviewPatchRequests }
  }

  func reviewBodyUpdateCallCount() -> Int {
    lock.withLock { reviewBodyUpdateRequests.count }
  }

  func lastReviewBodyUpdateRequest() -> RecordedReviewBodyUpdateRequest? {
    lock.withLock { reviewBodyUpdateRequests.last }
  }

  func updateReviewBody(
    request: ReviewsBodyUpdateRequest
  ) async throws -> ReviewsBodyUpdateResponse {
    let (response, error): (ReviewsBodyUpdateResponse?, (any Error)?) = lock.withLock {
      reviewBodyUpdateRequests.append(
        RecordedReviewBodyUpdateRequest(
          pullRequestID: request.pullRequestID,
          expectedPriorBodySHA256: request.expectedPriorBodySHA256,
          newBody: request.newBody
        )
      )
      return (
        reviewBodyUpdateOutcomes[request.pullRequestID],
        reviewBodyUpdateErrors[request.pullRequestID]
      )
    }
    if let error {
      throw error
    }
    if let response {
      return response
    }
    return ReviewsBodyUpdateResponse(
      pullRequestID: request.pullRequestID,
      outcome: .updated,
      currentBody: request.newBody,
      currentBodySHA256: "",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z"
    )
  }

  func commentReviews(
    request: ReviewsCommentRequest
  ) async throws -> ReviewsActionResponse {
    let (response, error): (ReviewsActionResponse?, (any Error)?) = lock.withLock {
      reviewCommentRequests.append(request)
      return (reviewCommentResponse, reviewCommentError)
    }
    if let error {
      throw error
    }
    if let response {
      return response
    }
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  func previewReviewFiles(
    request: ReviewsFilesPreviewRequest
  ) async throws -> ReviewsFilesPreviewResponse {
    let delay = lock.withLock {
      reviewPreviewRequests.append(request)
      return reviewPreviewDelay
    }
    try await sleepIfNeeded(delay)
    return ReviewsFilesPreviewResponse(
      pullRequestID: request.pullRequestID,
      previews: request.paths.map {
        ReviewFilePreview(
          path: $0,
          patch: "@@ -1 +1 @@\n-\($0)\n+\($0)\n",
          status: .modified,
          additions: 1,
          deletions: 1,
          servedBy: .githubRest,
          fetchedAt: "2026-05-23T12:00:00Z",
          headRefOid: request.headRefOidExpected,
          lineCount: 3,
          lineLimit: request.lineLimit,
          hasMore: false
        )
      },
      drifted: false,
      currentHeadRefOid: request.headRefOidExpected,
      fetchedAt: "2026-05-23T12:00:00Z"
    )
  }

  func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse {
    let delay = lock.withLock {
      reviewPatchRequests.append(request)
      return reviewPatchDelay
    }
    try await sleepIfNeeded(delay)
    return ReviewsFilesPatchResponse(
      pullRequestID: request.pullRequestID,
      patches: request.paths.map {
        ReviewFilePatch(
          path: $0,
          patch: "@@ -1 +1 @@\n-\($0)\n+\($0)-full\n",
          status: .modified,
          additions: 1,
          deletions: 1,
          servedBy: .githubRest,
          fetchedAt: "2026-05-23T12:00:00Z",
          headRefOid: request.headRefOidExpected
        )
      },
      drifted: false,
      currentHeadRefOid: request.headRefOidExpected,
      fetchedAt: "2026-05-23T12:00:00Z"
    )
  }
}
