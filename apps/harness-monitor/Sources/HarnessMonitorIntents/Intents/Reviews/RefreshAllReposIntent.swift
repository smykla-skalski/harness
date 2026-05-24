import AppIntents
import Foundation
import HarnessMonitorKit

public struct RefreshAllReposIntent: AppIntent {
  public static var title: LocalizedStringResource { "Refresh All Repositories" }
  public static var description: IntentDescription {
    IntentDescription(
      """
      Refresh every tracked repository without bringing Harness Monitor \
      to the foreground.
      """,
      categoryName: "Reviews",
      searchKeywords: ["refresh", "sync", "all", "reload", "everything"]
    )
  }

  let source: ReviewsRefreshSource

  public init() {
    self.source = DaemonReviewsRefreshSource()
  }

  init(source: ReviewsRefreshSource) {
    self.source = source
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try await source.refreshAll()
    await IntentWidgetReloader.shared.reloadNeedsMeCount()
    return .result(dialog: IntentDialog("Queued a refresh for every tracked repository"))
  }
}
