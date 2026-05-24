import AppIntents
import Foundation
import HarnessMonitorKit

public struct TaskBoardItemQuery: EntityQuery, EntityStringQuery, Sendable {
  public static let suggestedLimit = 25

  let source: TaskBoardItemSource
  let donationRecorder: IntentDonationRecorder

  public init() {
    self.source = DaemonTaskBoardItemSource()
    self.donationRecorder = .shared
  }

  init(
    source: TaskBoardItemSource,
    donationRecorder: IntentDonationRecorder = .shared
  ) {
    self.source = source
    self.donationRecorder = donationRecorder
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
    let ordered = await applyDonationBias(to: Array(items.prefix(Self.suggestedLimit)))
    return ordered.map(TaskBoardItemEntity.init(from:))
  }

  public func entities(matching string: String) async throws -> [TaskBoardItemEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return try await suggestedEntities()
    }
    let items = try await source.search(query: trimmed)
    return items.map(TaskBoardItemEntity.init(from:))
  }

  /// Bumps task-board items the user recently acted on (Dispatch or
  /// Approve Plan via App Intents) to the front. Order within the
  /// donation set is most-recent-first; everything else keeps its
  /// daemon-sorted order
  func applyDonationBias(to items: [TaskBoardItem]) async -> [TaskBoardItem] {
    let donatedIDs = await donationRecorder.recentIDs(kind: .taskBoardItem)
    guard !donatedIDs.isEmpty else { return items }

    let donatedSet = Set(donatedIDs)
    let donationOrder = Dictionary(
      uniqueKeysWithValues: donatedIDs.enumerated().map { ($1, $0) }
    )
    let promoted =
      items
      .filter { donatedSet.contains($0.id) }
      .sorted { lhs, rhs in
        (donationOrder[lhs.id] ?? .max)
          < (donationOrder[rhs.id] ?? .max)
      }
    let remainder = items.filter { !donatedSet.contains($0.id) }
    return promoted + remainder
  }
}
