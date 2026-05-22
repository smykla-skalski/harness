import Foundation

@testable import HarnessMonitorKit

private struct DependencyTimelineFetchResult {
  let hook: (@Sendable (String) async -> Void)?
  let response: DependencyUpdatesTimelineResponse?
  let error: (any Error)?
}

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

  func dependencyTimelineRequestedPageSizes(for pullRequestID: String) -> [UInt32] {
    lock.withLock {
      dependencyTimelineFetchedRequests
        .filter { $0.pullRequestId == pullRequestID }
        .map(\.pageSize)
    }
  }

  func fetchDependencyUpdateTimeline(
    request: DependencyUpdatesTimelineRequest
  ) async throws -> DependencyUpdatesTimelineResponse {
    let result = lock.withLock {
      dependencyTimelineFetchedRequests.append(request)
      let hook = dependencyTimelineFetchHook
      let error = dependencyTimelineErrors[request.pullRequestId]
      var queue = dependencyTimelineResponses[request.pullRequestId] ?? []
      let next = queue.isEmpty ? nil : queue.removeFirst()
      dependencyTimelineResponses[request.pullRequestId] = queue
      return DependencyTimelineFetchResult(hook: hook, response: next, error: error)
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
    return DependencyUpdatesTimelineResponse(
      pullRequestId: request.pullRequestId,
      entries: [],
      pageInfo: DependencyUpdateTimelinePageInfo(),
      viewerCanComment: true,
      fetchedAt: "2026-05-22T00:00:00Z"
    )
  }
}
