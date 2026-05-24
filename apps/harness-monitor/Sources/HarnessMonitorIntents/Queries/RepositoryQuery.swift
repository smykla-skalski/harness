import AppIntents
import Foundation
import HarnessMonitorKit

public struct RepositoryQuery: EntityQuery, EntityStringQuery, Sendable {
  let source: RepositorySource
  let donationRecorder: IntentDonationRecorder

  public init() {
    self.source = DaemonRepositorySource()
    self.donationRecorder = .shared
  }

  init(
    source: RepositorySource,
    donationRecorder: IntentDonationRecorder = .shared
  ) {
    self.source = source
    self.donationRecorder = donationRecorder
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
    let ordered = await applyDonationBias(to: raw)
    return ordered.compactMap(RepositoryEntity.init(rawIdentifier:))
  }

  public func entities(matching string: String) async throws -> [RepositoryEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return try await suggestedEntities()
    }
    let raw = try await source.search(query: trimmed)
    return raw.compactMap(RepositoryEntity.init(rawIdentifier:))
  }

  /// Bumps repositories the user recently refreshed via App Intents to
  /// the front. Order within the donation set is most-recent-first;
  /// everything else keeps its daemon-sorted order
  func applyDonationBias(to identifiers: [String]) async -> [String] {
    let donatedIDs = await donationRecorder.recentIDs(kind: .repository)
    guard !donatedIDs.isEmpty else { return identifiers }

    let donatedSet = Set(donatedIDs)
    let donationOrder = Dictionary(
      uniqueKeysWithValues: donatedIDs.enumerated().map { ($1, $0) }
    )
    let promoted =
      identifiers
      .filter { donatedSet.contains($0) }
      .sorted { lhs, rhs in
        (donationOrder[lhs] ?? .max) < (donationOrder[rhs] ?? .max)
      }
    let remainder = identifiers.filter { !donatedSet.contains($0) }
    return promoted + remainder
  }
}
