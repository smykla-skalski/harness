import AppIntents
import Foundation
import HarnessMonitorKit

public struct SearchPullRequestsIntent: AppIntent {
  public static var title: LocalizedStringResource { "Search Pull Requests" }
  public static var description: IntentDescription {
    IntentDescription(
      "Find pull requests by title, repository, or author",
      categoryName: "Reviews",
      searchKeywords: ["search", "find", "pull request", "pr"],
      resultValueName: "Pull Requests"
    )
  }

  @Parameter(title: "Query")
  public var query: String

  let source: PullRequestSource

  public init() {
    self.source = DaemonPullRequestSource()
  }

  init(query: String, source: PullRequestSource) {
    self.source = source
    self.query = query
  }

  public func perform() async throws -> some IntentResult & ReturnsValue<[PullRequestEntity]> {
    let entities = try await resolveEntities()
    return .result(value: entities)
  }

  func resolveEntities() async throws -> [PullRequestEntity] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let items = try await source.search(query: trimmed, limit: 50)
    let ranked = IntentSearchRanker.rank(items: items, query: trimmed)
    return ranked.map(PullRequestEntity.init(from:))
  }
}
