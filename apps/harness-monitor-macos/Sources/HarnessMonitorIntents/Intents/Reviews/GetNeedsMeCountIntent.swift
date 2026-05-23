import AppIntents
import Foundation
import HarnessMonitorKit

public struct GetNeedsMeCountIntent: AppIntent {
  public static var title: LocalizedStringResource { "Get Needs-Me Count" }
  public static var description: IntentDescription {
    IntentDescription(
      "Count the pull requests that are currently waiting on your review.",
      categoryName: "Reviews",
      searchKeywords: ["count", "needs me", "review queue", "pending"],
      resultValueName: "Count"
    )
  }

  let source: PullRequestSource

  public init() {
    self.source = DaemonPullRequestSource()
  }

  init(source: PullRequestSource) {
    self.source = source
  }

  public func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
    let count = try await resolveCount()
    return .result(value: count, dialog: Self.dialog(for: count))
  }

  public func resolveCount() async throws -> Int {
    let items = try await source.suggested(limit: 1000)
    return items.filter(\.requiresAttention).count
  }

  static func dialog(for count: Int) -> IntentDialog {
    switch count {
    case 0:
      return IntentDialog("Nothing needs your review right now.")
    case 1:
      return IntentDialog("1 pull request needs your review.")
    default:
      return IntentDialog("\(count) pull requests need your review.")
    }
  }
}
