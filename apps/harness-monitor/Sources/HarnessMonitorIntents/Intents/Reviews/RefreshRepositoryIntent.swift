import AppIntents
import Foundation
import HarnessMonitorKit

public struct RefreshRepositoryIntent: AppIntent {
  public static var title: LocalizedStringResource { "Refresh Repository" }
  public static var description: IntentDescription {
    IntentDescription(
      """
      Refresh pull requests for a specific repository without bringing \
      Harness Monitor to the foreground.
      """,
      categoryName: "Reviews",
      searchKeywords: ["refresh", "sync", "repository", "repo", "reload"],
      resultValueName: "Refreshed Pull Request Count"
    )
  }

  @Parameter(title: "Repository")
  public var repository: RepositoryEntity

  let source: ReviewsRefreshSource

  public init() {
    self.source = DaemonReviewsRefreshSource()
  }

  init(repository: RepositoryEntity, source: ReviewsRefreshSource) {
    self.source = source
    self.repository = repository
  }

  public func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
    let count = try await resolveRefreshCount()
    return .result(value: count, dialog: Self.dialog(for: count, repository: repository.id))
  }

  func resolveRefreshCount() async throws -> Int {
    try await source.refreshRepository(repository.id)
  }

  static func dialog(for count: Int, repository: String) -> IntentDialog {
    let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
    let repoName = trimmed.isEmpty ? "the requested repository" : trimmed
    switch count {
    case 0:
      return IntentDialog("No open pull requests for \(repoName).")
    case 1:
      return IntentDialog("Refreshed 1 pull request for \(repoName).")
    default:
      return IntentDialog("Refreshed \(count) pull requests for \(repoName).")
    }
  }
}
