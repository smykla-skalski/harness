import AppIntents
import Foundation
import HarnessMonitorKit

public struct PullRequestQuery: EntityQuery, EntityStringQuery, Sendable {
  public static let suggestedLimit = 20
  public static let searchLimit = 50

  let source: PullRequestSource

  public init() {
    self.source = DaemonPullRequestSource()
  }

  init(source: PullRequestSource) {
    self.source = source
  }

  public func entities(for identifiers: [PullRequestEntity.ID]) async throws -> [PullRequestEntity]
  {
    let unique = Array(NSOrderedSet(array: identifiers)) as? [String] ?? identifiers
    guard !unique.isEmpty else { return [] }
    let items = try await source.fetch(ids: unique)
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.pullRequestID, $0) })
    return unique.compactMap { byID[$0] }.map(PullRequestEntity.init(from:))
  }

  public func suggestedEntities() async throws -> [PullRequestEntity] {
    let items = try await source.suggested(limit: Self.suggestedLimit)
    return
      items
      .filter(\.requiresAttention)
      .map(PullRequestEntity.init(from:))
  }

  public func entities(matching string: String) async throws -> [PullRequestEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return try await suggestedEntities()
    }
    let items = try await source.search(query: trimmed, limit: Self.searchLimit)
    return items.map(PullRequestEntity.init(from:))
  }
}
