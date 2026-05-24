import Foundation
import HarnessMonitorKit

public protocol ReviewsRefreshSource: Sendable {
  func refreshAll() async throws
  func refreshRepository(_ repository: String) async throws -> Int
}

struct DaemonReviewsRefreshSource: ReviewsRefreshSource {
  let environment: HarnessMonitorEnvironment
  let cache: IntentDaemonClientCache

  init(
    environment: HarnessMonitorEnvironment = .current,
    cache: IntentDaemonClientCache = .shared
  ) {
    self.environment = environment
    self.cache = cache
  }

  func refreshAll() async throws {
    let client = try await cache.client(for: environment)
    do {
      try await client.refreshAllReviews()
    } catch {
      await cache.invalidate()
      throw error
    }
  }

  func refreshRepository(_ repository: String) async throws -> Int {
    let client = try await cache.client(for: environment)
    do {
      return try await client.refreshRepositoryReviews(repository: repository)
    } catch {
      await cache.invalidate()
      throw error
    }
  }
}
