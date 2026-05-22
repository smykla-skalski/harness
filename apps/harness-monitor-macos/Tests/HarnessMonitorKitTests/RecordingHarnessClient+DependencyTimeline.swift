import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func configureDependencyTimeline(
    pullRequestID: String,
    responses: [DependencyUpdatesTimelineResponse]
  ) {
    lock.withLock {
      dependencyTimelineResponses[pullRequestID] = responses
    }
  }

  func enqueueDependencyTimelineResponse(_ response: DependencyUpdatesTimelineResponse) {
    lock.withLock {
      dependencyTimelineResponses[response.pullRequestId, default: []].append(response)
    }
  }

  func setDependencyTimelineFetchHook(_ hook: @escaping @Sendable (String) async -> Void) {
    lock.withLock {
      dependencyTimelineFetchHook = hook
    }
  }

  func configureDependencyTimelineError(pullRequestID: String, error: any Error) {
    lock.withLock {
      dependencyTimelineErrors[pullRequestID] = error
    }
  }

  func dependencyTimelineFetchCount() -> Int {
    lock.withLock { dependencyTimelineFetchedRequests.count }
  }

  func dependencyTimelineRequestedCursors(for pullRequestID: String) -> [String?] {
    lock.withLock {
      dependencyTimelineFetchedRequests
        .filter { $0.pullRequestId == pullRequestID }
        .map(\.cursor)
    }
  }

  func fetchDependencyUpdateTimeline(
    request: DependencyUpdatesTimelineRequest
  ) async throws -> DependencyUpdatesTimelineResponse {
    let (hook, queued, error): (
      (@Sendable (String) async -> Void)?,
      DependencyUpdatesTimelineResponse?,
      (any Error)?
    ) = lock.withLock {
      dependencyTimelineFetchedRequests.append(request)
      let hook = dependencyTimelineFetchHook
      let error = dependencyTimelineErrors[request.pullRequestId]
      var queue = dependencyTimelineResponses[request.pullRequestId] ?? []
      let next = queue.isEmpty ? nil : queue.removeFirst()
      dependencyTimelineResponses[request.pullRequestId] = queue
      return (hook, next, error)
    }
    if let hook {
      await hook(request.pullRequestId)
    }
    if let error {
      throw error
    }
    if let queued {
      return queued
    }
    return DependencyUpdatesTimelineResponse(
      pullRequestId: request.pullRequestId,
      entries: [],
      pageInfo: DependencyUpdateTimelinePageInfo(),
      viewerCanComment: true,
      fetchedAt: "2026-05-22T00:00:00Z"
    )
  }
}
