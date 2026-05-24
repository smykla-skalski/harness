import Foundation
import HarnessMonitorKit

struct DaemonPullRequestSource: PullRequestSource {
  let environment: HarnessMonitorEnvironment
  let cache: IntentDaemonClientCache

  init(
    environment: HarnessMonitorEnvironment = .current,
    cache: IntentDaemonClientCache = .shared
  ) {
    self.environment = environment
    self.cache = cache
  }

  func fetch(ids: [String]) async throws -> [ReviewItem] {
    try await runRPC { client in
      try await client.fetchReviewItems(ids: ids)
    }
  }

  func suggested(limit: Int) async throws -> [ReviewItem] {
    try await runRPC { client in
      try await client.suggestedReviewItems(limit: limit)
    }
  }

  func search(query: String, limit: Int) async throws -> [ReviewItem] {
    try await runRPC { client in
      try await client.searchReviewItems(query: query, limit: limit)
    }
  }

  private func runRPC<T: Sendable>(
    _ body: @Sendable (IntentDaemonClient) async throws -> T
  ) async throws -> T {
    let client = try await cache.client(for: environment)
    do {
      return try await body(client)
    } catch {
      await cache.invalidate()
      throw error
    }
  }
}
