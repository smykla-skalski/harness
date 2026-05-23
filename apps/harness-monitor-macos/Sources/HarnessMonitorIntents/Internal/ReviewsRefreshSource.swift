import Foundation
import HarnessMonitorKit

public protocol ReviewsRefreshSource: Sendable {
  func refreshAll() async throws
  func refreshRepository(_ repository: String) async throws -> Int
}

struct DaemonReviewsRefreshSource: ReviewsRefreshSource {
  let environment: HarnessMonitorEnvironment

  init(environment: HarnessMonitorEnvironment = .current) {
    self.environment = environment
  }

  func refreshAll() async throws {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    try await client.refreshAllReviews()
  }

  func refreshRepository(_ repository: String) async throws -> Int {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.refreshRepositoryReviews(repository: repository)
  }
}
