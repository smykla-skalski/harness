import Foundation
import HarnessMonitorKit

struct ReviewPullRequestExtractionResult: Equatable, Sendable {
  let rows: [ReviewPullRequestExtractionResolvedRow]
  let outputText: String

  var matchedItems: [ReviewItem] {
    orderedUniqueItems(rows.compactMap(\.item))
  }

  var selectedItems: [ReviewItem] {
    orderedUniqueItems(rows.filter(\.isSelectedForOutput).compactMap(\.item))
  }

  var missingRows: [ReviewPullRequestExtractionResolvedRow] {
    rows.filter { $0.status == .missing }
  }

  var ambiguousRows: [ReviewPullRequestExtractionResolvedRow] {
    rows.filter { $0.status == .ambiguous }
  }

  private func orderedUniqueItems(_ items: [ReviewItem]) -> [ReviewItem] {
    var seen = Set<String>()
    return items.filter { item in
      seen.insert(item.pullRequestID).inserted
    }
  }
}

struct ReviewPullRequestExtractionResolvedRow: Equatable, Identifiable, Sendable {
  enum Status: Equatable, Sendable {
    case matched
    case missing
    case ambiguous
  }

  let row: ReviewPullRequestExtractionRow
  let status: Status
  let item: ReviewItem?
  let ambiguousItems: [ReviewItem]
  let isSelectedForOutput: Bool

  var id: Int { row.id }
}

struct ReviewPullRequestExtractionContext: Sendable {
  typealias RepositoryFetcher = @MainActor @Sendable ([String]) async -> [ReviewItem]

  let currentItems: [ReviewItem]
  let configuredRepositories: [String]
  let activeReviewsRepository: String?
  let configuration: ReviewPullRequestExtractionConfiguration
  let fetchRepositories: RepositoryFetcher?
}

enum ReviewPullRequestExtractionService {
  static func resolve(
    rows: [ReviewPullRequestExtractionRow],
    context: ReviewPullRequestExtractionContext
  ) async -> ReviewPullRequestExtractionResult {
    let repositoryScope = repositories(for: context)
    var items = context.currentItems
    var resolved = resolveRows(rows, items: items, configuration: context.configuration)
    let repositories = await repositoriesToRefresh(
      rows: resolved,
      repositoryScope: repositoryScope,
      configuration: context.configuration
    )

    if !repositories.isEmpty, let fetchRepositories = context.fetchRepositories {
      let fetchedItems = await fetchRepositories(repositories)
      items = mergeItems(items, fetchedItems)
      resolved = resolveRows(rows, items: items, configuration: context.configuration)
    }

    let matchedItems = resolved.compactMap(\.item)
    if context.configuration.numberMemoryEnabled {
      await ReviewPullRequestNumberMemory.shared.learn(items: matchedItems)
    }
    let outputText = output(from: resolved, format: context.configuration.outputFormat)
    return ReviewPullRequestExtractionResult(rows: resolved, outputText: outputText)
  }

  static func rows(from references: [GitHubPullRequestReference])
    -> [ReviewPullRequestExtractionRow]
  {
    references.enumerated().map { index, reference in
      ReviewPullRequestExtractionRow(
        rowIndex: index,
        reference: .resolved(reference),
        text: reference.rawMatch,
        titleText: "",
        branchText: "",
        visualStatus: .unknown,
        normalizedBoundingBox: nil
      )
    }
  }

  static func output(
    from rows: [ReviewPullRequestExtractionResolvedRow],
    format: ReviewPullRequestExtractionConfiguration.OutputFormat
  ) -> String {
    orderedUniqueItems(rows.filter(\.isSelectedForOutput).compactMap(\.item))
      .map { outputLine(for: $0, format: format) }
      .joined(separator: "\n")
  }

  static func resetNumberMemoryForTesting() async {
    await ReviewPullRequestNumberMemory.shared.resetForTesting()
  }

  private static func resolveRows(
    _ rows: [ReviewPullRequestExtractionRow],
    items: [ReviewItem],
    configuration: ReviewPullRequestExtractionConfiguration
  ) -> [ReviewPullRequestExtractionResolvedRow] {
    let index = ReviewPullRequestItemIndex(items: items)
    return rows.map { row in
      let match = index.match(for: row.reference)
      let selected = match.item.map {
        shouldInclude(item: $0, row: row, configuration: configuration)
      } ?? false
      return ReviewPullRequestExtractionResolvedRow(
        row: row,
        status: match.status,
        item: match.item,
        ambiguousItems: match.ambiguousItems,
        isSelectedForOutput: selected
      )
    }
  }

  private static func repositoriesToRefresh(
    rows: [ReviewPullRequestExtractionResolvedRow],
    repositoryScope: [String],
    configuration: ReviewPullRequestExtractionConfiguration
  ) async -> [String] {
    let missingFullRefs = rows.compactMap { row -> String? in
      guard row.status == .missing, let repository = row.row.reference.repository else {
        return nil
      }
      return repository
    }
    let bareNumbers = rows.compactMap { row -> UInt64? in
      guard row.row.reference.repository == nil && row.status != .matched else {
        return nil
      }
      return row.row.reference.number
    }
    let needsBareRefresh = !bareNumbers.isEmpty
    var rememberedRepositories: [String] = []
    if configuration.numberMemoryEnabled {
      for number in bareNumbers {
        rememberedRepositories.append(
          contentsOf: await ReviewPullRequestNumberMemory.shared.repositories(for: number)
        )
      }
    }
    let scopeRepositories =
      needsBareRefresh
      ? repositoryScope
      : []
    return orderedUnique(missingFullRefs + rememberedRepositories + scopeRepositories)
  }

  private static func repositories(
    for context: ReviewPullRequestExtractionContext
  ) -> [String] {
    switch context.configuration.repositoryMode {
    case .allConfiguredRepos:
      return context.configuredRepositories
    case .policyRepositories:
      return context.configuration.policyRepositories
    case .activeReviewsRepository:
      return context.activeReviewsRepository.map { [$0] } ?? context.configuredRepositories
    }
  }

  private static func mergeItems(_ lhs: [ReviewItem], _ rhs: [ReviewItem]) -> [ReviewItem] {
    var byID = Dictionary(uniqueKeysWithValues: lhs.map { ($0.pullRequestID, $0) })
    for item in rhs {
      byID[item.pullRequestID] = item
    }
    return Array(byID.values)
  }

  private static func shouldInclude(
    item: ReviewItem,
    row: ReviewPullRequestExtractionRow,
    configuration: ReviewPullRequestExtractionConfiguration
  ) -> Bool {
    guard configuration.resultScope == .failing else { return true }
    switch configuration.failureSignalMode {
    case .liveReviews:
      return item.hasLiveReviewFailureSignal
    case .visualScreenshot:
      return row.visualStatus == .failing
    case .liveOrVisual:
      return item.hasLiveReviewFailureSignal || row.visualStatus == .failing
    }
  }

  private static func outputLine(
    for item: ReviewItem,
    format: ReviewPullRequestExtractionConfiguration.OutputFormat
  ) -> String {
    switch format {
    case .newlineGitHubURLs:
      item.url
    case .ownerRepoNumber:
      "\(item.repository)#\(item.number)"
    case .markdownLinks:
      "[\(item.repository)#\(item.number)](\(item.url))"
    }
  }

  private static func orderedUnique(_ repositories: [String]) -> [String] {
    var seen = Set<String>()
    return repositories.filter { repository in
      seen.insert(repository.lowercased()).inserted
    }
  }

  private static func orderedUniqueItems(_ items: [ReviewItem]) -> [ReviewItem] {
    var seen = Set<String>()
    return items.filter { item in
      seen.insert(item.pullRequestID).inserted
    }
  }
}

private struct ReviewPullRequestItemIndex {
  let byReference: [String: ReviewItem]
  let byNumber: [UInt64: [ReviewItem]]

  init(items: [ReviewItem]) {
    var byReference: [String: ReviewItem] = [:]
    var byNumber: [UInt64: [ReviewItem]] = [:]
    for item in items {
      byReference["\(item.repository.lowercased())#\(item.number)"] = item
      byNumber[item.number, default: []].append(item)
    }
    self.byReference = byReference
    self.byNumber = byNumber
  }

  func match(
    for reference: ReviewPullRequestExtractionReference
  ) -> (status: ReviewPullRequestExtractionResolvedRow.Status, item: ReviewItem?, ambiguousItems: [ReviewItem]) {
    switch reference {
    case .resolved(let reference):
      guard let item = byReference[reference.id] else {
        return (.missing, nil, [])
      }
      return (.matched, item, [])
    case .bare(let number, _):
      let items = byNumber[number] ?? []
      if items.count == 1 {
        return (.matched, items[0], [])
      }
      return items.isEmpty ? (.missing, nil, []) : (.ambiguous, nil, items)
    }
  }
}

private actor ReviewPullRequestNumberMemory {
  static let shared = ReviewPullRequestNumberMemory()

  private var repositoriesByNumber: [UInt64: [String]] = [:]

  func learn(items: [ReviewItem]) {
    for item in items {
      var repositories = repositoriesByNumber[item.number] ?? []
      if !repositories.contains(where: { $0.caseInsensitiveCompare(item.repository) == .orderedSame }) {
        repositories.append(item.repository)
      }
      repositoriesByNumber[item.number] = repositories
    }
  }

  func repositories(for number: UInt64) -> [String] {
    repositoriesByNumber[number] ?? []
  }

  func resetForTesting() {
    repositoriesByNumber.removeAll()
  }
}

extension ReviewItem {
  var hasLiveReviewFailureSignal: Bool {
    checkStatus == .failure
      || !requiredFailedCheckNames.isEmpty
      || reviewStatus == .changesRequested
      || mergeable == .conflicting
      || policyBlocked
  }
}
