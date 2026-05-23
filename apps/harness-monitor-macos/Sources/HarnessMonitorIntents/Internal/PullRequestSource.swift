import Foundation
import HarnessMonitorKit

public protocol PullRequestSource: Sendable {
  func fetch(ids: [String]) async throws -> [ReviewItem]
  func suggested(limit: Int) async throws -> [ReviewItem]
  func search(query: String, limit: Int) async throws -> [ReviewItem]
}

struct UnwiredPullRequestSource: PullRequestSource {
  func fetch(ids: [String]) async throws -> [ReviewItem] {
    throw IntentDaemonError.daemonUnavailable(
      reason: "Pull-request lookup is not wired to the daemon yet."
    )
  }

  func suggested(limit: Int) async throws -> [ReviewItem] {
    throw IntentDaemonError.daemonUnavailable(
      reason: "Pull-request suggestions are not wired to the daemon yet."
    )
  }

  func search(query: String, limit: Int) async throws -> [ReviewItem] {
    throw IntentDaemonError.daemonUnavailable(
      reason: "Pull-request search is not wired to the daemon yet."
    )
  }
}
