import Foundation
import HarnessMonitorKit

public protocol ReviewsActionSource: Sendable {
  func approve(pullRequestID: String) async throws
  func merge(pullRequestID: String, method: TaskBoardGitHubMergeMethod) async throws
  func rerunChecks(pullRequestID: String) async throws
  func addLabel(pullRequestID: String, label: String) async throws
}

struct DaemonReviewsActionSource: ReviewsActionSource {
  let environment: HarnessMonitorEnvironment
  let cache: IntentDaemonClientCache

  init(
    environment: HarnessMonitorEnvironment = .current,
    cache: IntentDaemonClientCache = .shared
  ) {
    self.environment = environment
    self.cache = cache
  }

  func approve(pullRequestID: String) async throws {
    try await runRPC { client in
      try await client.approve(pullRequestID: pullRequestID)
    }
  }

  func merge(pullRequestID: String, method: TaskBoardGitHubMergeMethod) async throws {
    try await runRPC { client in
      try await client.merge(pullRequestID: pullRequestID, method: method)
    }
  }

  func rerunChecks(pullRequestID: String) async throws {
    try await runRPC { client in
      try await client.rerunChecks(pullRequestID: pullRequestID)
    }
  }

  func addLabel(pullRequestID: String, label: String) async throws {
    try await runRPC { client in
      try await client.addLabel(pullRequestID: pullRequestID, label: label)
    }
  }

  private func runRPC(
    _ body: @Sendable (IntentDaemonClient) async throws -> Void
  ) async throws {
    let client = try await cache.client(for: environment)
    do {
      try await body(client)
    } catch {
      await cache.invalidate()
      throw error
    }
  }
}
