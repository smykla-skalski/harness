import Foundation
import HarnessMonitorKit

public protocol PullRequestSource: Sendable {
  func fetch(ids: [String]) async throws -> [ReviewItem]
  func suggested(limit: Int) async throws -> [ReviewItem]
  func search(query: String, limit: Int) async throws -> [ReviewItem]
}
