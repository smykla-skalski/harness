import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func configureDependencyBody(
    pullRequestID: String,
    body: String,
    prUpdatedAt: String = "2026-05-21T00:00:00Z",
    fetchedAt: String = "2026-05-21T00:00:00Z"
  ) {
    lock.withLock {
      dependencyBodyResponses[pullRequestID] = DependencyUpdatesBodyResponse(
        pullRequestID: pullRequestID,
        body: body,
        prUpdatedAt: prUpdatedAt,
        fetchedAt: fetchedAt,
        fromCache: false
      )
    }
  }

  /// Closure runs inside `fetchDependencyUpdateBody` before the response
  /// resolves; lets tests suspend the first fetch so a concurrent caller
  /// can observe in-flight dedupe.
  func setDependencyBodyFetchHook(_ hook: @escaping @Sendable (String) async -> Void) {
    lock.withLock {
      dependencyBodyFetchHook = hook
    }
  }

  func dependencyBodyFetchCount() -> Int {
    lock.withLock { dependencyBodyFetchedIDs.count }
  }

  func fetchDependencyUpdateBody(
    request: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse {
    let (hook, response):
      (
        (@Sendable (String) async -> Void)?, DependencyUpdatesBodyResponse?
      ) = lock.withLock {
        dependencyBodyFetchedIDs.append(request.pullRequestID)
        return (dependencyBodyFetchHook, dependencyBodyResponses[request.pullRequestID])
      }
    if let hook {
      await hook(request.pullRequestID)
    }
    if let response {
      return response
    }
    return DependencyUpdatesBodyResponse(
      pullRequestID: request.pullRequestID,
      body: "",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z",
      fromCache: false
    )
  }

  func configureDependencyBodyUpdate(
    pullRequestID: String,
    outcome: DependencyUpdatesBodyUpdateOutcome,
    currentBody: String,
    currentBodySHA256: String = "",
    prUpdatedAt: String = "2026-05-21T00:00:00Z",
    fetchedAt: String = "2026-05-21T00:00:00Z"
  ) {
    lock.withLock {
      dependencyBodyUpdateOutcomes[pullRequestID] = DependencyUpdatesBodyUpdateResponse(
        pullRequestID: pullRequestID,
        outcome: outcome,
        currentBody: currentBody,
        currentBodySHA256: currentBodySHA256,
        prUpdatedAt: prUpdatedAt,
        fetchedAt: fetchedAt
      )
    }
  }

  func configureDependencyBodyUpdateError(pullRequestID: String, error: any Error) {
    lock.withLock {
      dependencyBodyUpdateErrors[pullRequestID] = error
    }
  }

  func configureDependencyCommentResponse(_ response: DependencyUpdatesActionResponse) {
    lock.withLock {
      dependencyCommentResponse = response
    }
  }

  func configureDependencyCommentError(_ error: any Error) {
    lock.withLock {
      dependencyCommentError = error
    }
  }

  func dependencyBodyUpdateCallCount() -> Int {
    lock.withLock { dependencyBodyUpdateRequests.count }
  }

  func lastDependencyBodyUpdateRequest() -> RecordedDependencyBodyUpdateRequest? {
    lock.withLock { dependencyBodyUpdateRequests.last }
  }

  func updateDependencyUpdateBody(
    request: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse {
    let (response, error): (DependencyUpdatesBodyUpdateResponse?, (any Error)?) = lock.withLock {
      dependencyBodyUpdateRequests.append(
        RecordedDependencyBodyUpdateRequest(
          pullRequestID: request.pullRequestID,
          expectedPriorBodySHA256: request.expectedPriorBodySHA256,
          newBody: request.newBody
        )
      )
      return (
        dependencyBodyUpdateOutcomes[request.pullRequestID],
        dependencyBodyUpdateErrors[request.pullRequestID]
      )
    }
    if let error {
      throw error
    }
    if let response {
      return response
    }
    return DependencyUpdatesBodyUpdateResponse(
      pullRequestID: request.pullRequestID,
      outcome: .updated,
      currentBody: request.newBody,
      currentBodySHA256: "",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z"
    )
  }

  func commentDependencyUpdates(
    request: DependencyUpdatesCommentRequest
  ) async throws -> DependencyUpdatesActionResponse {
    let (response, error): (DependencyUpdatesActionResponse?, (any Error)?) = lock.withLock {
      dependencyCommentRequests.append(request)
      return (dependencyCommentResponse, dependencyCommentError)
    }
    if let error {
      throw error
    }
    if let response {
      return response
    }
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }
}
