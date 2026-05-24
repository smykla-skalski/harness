import Foundation
import HarnessMonitorKit

extension IntentDaemonClient {
  public func fetchReviewItems(ids: [String]) async throws -> [ReviewItem] {
    guard !ids.isEmpty else { return [] }
    let response = try await queryReviewsCurrentSnapshot()
    let needles = Set(ids)
    let byID = Dictionary(uniqueKeysWithValues: response.items.map { ($0.pullRequestID, $0) })
    return ids.compactMap { byID[$0] }.filter { needles.contains($0.pullRequestID) }
  }

  public func suggestedReviewItems(limit: Int) async throws -> [ReviewItem] {
    let response = try await queryReviewsCurrentSnapshot()
    return Array(response.items.prefix(max(0, limit)))
  }

  public func searchReviewItems(query: String, limit: Int) async throws -> [ReviewItem] {
    let response = try await queryReviewsCurrentSnapshot()
    let needle = query.lowercased()
    guard !needle.isEmpty else { return [] }
    return Array(
      response.items
        .filter { Self.matches(item: $0, needle: needle) }
        .prefix(max(0, limit))
    )
  }

  public func countNeedsMeReviewItems() async throws -> Int {
    let response = try await queryReviewsCurrentSnapshot()
    return response.items.filter(\.requiresAttention).count
  }

  func queryReviewsCurrentSnapshot() async throws -> ReviewsQueryResponse {
    do {
      return try await transport.queryReviews(request: ReviewsQueryRequest())
    } catch {
      throw IntentDaemonError.rpcFailed(
        method: "reviews.query",
        message: error.localizedDescription
      )
    }
  }

  private static func matches(item: ReviewItem, needle: String) -> Bool {
    item.title.lowercased().contains(needle)
      || item.repository.lowercased().contains(needle)
      || item.authorLogin.lowercased().contains(needle)
      || item.pullRequestID.lowercased().contains(needle)
  }
}
