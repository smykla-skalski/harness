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
    let (hook, response): (
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
}
