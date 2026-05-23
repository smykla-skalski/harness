import AppIntents
import Foundation
import HarnessMonitorKit

public struct TaskBoardItemQuery: EntityQuery, EntityStringQuery, Sendable {
  public static let suggestedLimit = 25

  let source: TaskBoardItemSource

  public init() {
    self.source = DaemonTaskBoardItemSource()
  }

  init(source: TaskBoardItemSource) {
    self.source = source
  }

  public func entities(for identifiers: [TaskBoardItemEntity.ID]) async throws
    -> [TaskBoardItemEntity]
  {
    let unique = Array(NSOrderedSet(array: identifiers)) as? [String] ?? identifiers
    guard !unique.isEmpty else { return [] }
    let items = try await source.fetch(ids: unique)
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    return unique.compactMap { byID[$0] }.map(TaskBoardItemEntity.init(from:))
  }

  public func suggestedEntities() async throws -> [TaskBoardItemEntity] {
    let items = try await source.list(status: nil)
    return
      items
      .prefix(Self.suggestedLimit)
      .map(TaskBoardItemEntity.init(from:))
  }

  public func entities(matching string: String) async throws -> [TaskBoardItemEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return try await suggestedEntities()
    }
    let items = try await source.search(query: trimmed)
    return items.map(TaskBoardItemEntity.init(from:))
  }
}
