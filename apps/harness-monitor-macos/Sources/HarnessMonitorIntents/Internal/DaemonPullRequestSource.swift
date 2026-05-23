import Foundation
import HarnessMonitorKit

struct DaemonPullRequestSource: PullRequestSource {
  let environment: HarnessMonitorEnvironment

  init(environment: HarnessMonitorEnvironment = .current) {
    self.environment = environment
  }

  func fetch(ids: [String]) async throws -> [ReviewItem] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.fetchReviewItems(ids: ids)
  }

  func suggested(limit: Int) async throws -> [ReviewItem] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.suggestedReviewItems(limit: limit)
  }

  func search(query: String, limit: Int) async throws -> [ReviewItem] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.searchReviewItems(query: query, limit: limit)
  }
}
