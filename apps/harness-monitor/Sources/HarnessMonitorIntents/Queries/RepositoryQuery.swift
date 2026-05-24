import AppIntents
import Foundation
import HarnessMonitorKit

public struct RepositoryQuery: EntityQuery, EntityStringQuery, Sendable {
  let source: RepositorySource

  public init() {
    self.source = DaemonRepositorySource()
  }

  init(source: RepositorySource) {
    self.source = source
  }

  public func entities(for identifiers: [RepositoryEntity.ID]) async throws -> [RepositoryEntity] {
    let unique = Array(NSOrderedSet(array: identifiers)) as? [String] ?? identifiers
    guard !unique.isEmpty else { return [] }
    let available = try await source.suggested()
    let availableSet = Set(available)
    return unique.compactMap { rawID in
      guard availableSet.contains(rawID) else { return nil }
      return RepositoryEntity(rawIdentifier: rawID)
    }
  }

  public func suggestedEntities() async throws -> [RepositoryEntity] {
    let raw = try await source.suggested()
    return raw.compactMap(RepositoryEntity.init(rawIdentifier:))
  }

  public func entities(matching string: String) async throws -> [RepositoryEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return try await suggestedEntities()
    }
    let raw = try await source.search(query: trimmed)
    return raw.compactMap(RepositoryEntity.init(rawIdentifier:))
  }
}
