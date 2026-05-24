import AppIntents
import Foundation
import HarnessMonitorKit

public struct PullRequestQuery: EntityQuery, EntityStringQuery, Sendable {
  public static let suggestedLimit = 20
  public static let searchLimit = 50

  let source: PullRequestSource
  let donationRecorder: IntentDonationRecorder

  public init() {
    self.source = DaemonPullRequestSource()
    self.donationRecorder = .shared
  }

  init(
    source: PullRequestSource,
    donationRecorder: IntentDonationRecorder = .shared
  ) {
    self.source = source
    self.donationRecorder = donationRecorder
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
    let attentionItems = items.filter(\.requiresAttention)
    let ordered = await applyDonationBias(to: attentionItems)
    return ordered.map(PullRequestEntity.init(from:))
  }

  public func entities(matching string: String) async throws -> [PullRequestEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return try await suggestedEntities()
    }
    let items = try await source.search(query: trimmed, limit: Self.searchLimit)
    return items.map(PullRequestEntity.init(from:))
  }

  /// Bumps PRs the user recently acted on (via App Intent donations)
  /// to the front of the result. Order within the donation set is
  /// most-recent-first; everything else keeps its daemon-sorted order
  func applyDonationBias(to items: [ReviewItem]) async -> [ReviewItem] {
    let donatedIDs = await donationRecorder.recentIDs()
    guard !donatedIDs.isEmpty else { return items }

    let donatedSet = Set(donatedIDs)
    let donationOrder = Dictionary(
      uniqueKeysWithValues: donatedIDs.enumerated().map { ($1, $0) }
    )
    let promoted =
      items
      .filter { donatedSet.contains($0.pullRequestID) }
      .sorted { lhs, rhs in
        (donationOrder[lhs.pullRequestID] ?? .max)
          < (donationOrder[rhs.pullRequestID] ?? .max)
      }
    let remainder = items.filter { !donatedSet.contains($0.pullRequestID) }
    return promoted + remainder
  }
}
