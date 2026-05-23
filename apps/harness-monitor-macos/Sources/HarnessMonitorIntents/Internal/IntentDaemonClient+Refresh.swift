import Foundation
import HarnessMonitorKit

extension IntentDaemonClient {
  public func refreshAllReviews() async throws {
    do {
      _ = try await transport.queryReviews(
        request: ReviewsQueryRequest(forceRefresh: true, cacheMaxAgeSeconds: 0)
      )
    } catch {
      throw IntentDaemonError.rpcFailed(
        method: "reviews.query(forceRefresh)",
        message: error.localizedDescription
      )
    }
  }

  public func refreshRepositoryReviews(repository: String) async throws -> Int {
    let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    do {
      let response = try await transport.queryReviews(
        request: ReviewsQueryRequest(
          repositories: [trimmed],
          forceRefresh: true,
          cacheMaxAgeSeconds: 0
        )
      )
      return response.items.count
    } catch {
      throw IntentDaemonError.rpcFailed(
        method: "reviews.query(repositories=\(trimmed))",
        message: error.localizedDescription
      )
    }
  }
}
