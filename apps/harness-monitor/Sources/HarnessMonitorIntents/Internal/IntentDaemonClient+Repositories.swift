import Foundation
import HarnessMonitorKit

extension IntentDaemonClient {
  public func suggestedRepositoryIDs() async throws -> [String] {
    try await uniqueSortedRepositories(filter: nil)
  }

  public func searchRepositoryIDs(query: String) async throws -> [String] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return [] }
    return try await uniqueSortedRepositories(filter: needle)
  }

  private func uniqueSortedRepositories(filter: String?) async throws -> [String] {
    let response = try await queryReviewsCurrentSnapshot()
    var seen = Set<String>()
    var order: [String] = []
    for item in response.items {
      let repository = item.repository
      guard !repository.isEmpty, !seen.contains(repository) else { continue }
      if let filter, !repository.lowercased().contains(filter) {
        continue
      }
      seen.insert(repository)
      order.append(repository)
    }
    return order.sorted()
  }
}
