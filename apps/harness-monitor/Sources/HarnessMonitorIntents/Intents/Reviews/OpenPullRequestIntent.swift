import AppIntents
import AppKit
import Foundation
import HarnessMonitorKit

public struct OpenPullRequestIntent: OpenIntent {
  public static var title: LocalizedStringResource { "Open Pull Request" }
  public static var description: IntentDescription {
    IntentDescription(
      "Bring Harness Monitor to the front with this pull request selected in Reviews",
      categoryName: "Reviews",
      searchKeywords: ["pull request", "pr", "open", "review"]
    )
  }
  public static var openAppWhenRun: Bool { true }

  @Parameter(title: "Pull Request")
  public var target: PullRequestEntity

  public init() {}

  public init(target: PullRequestEntity) {
    self.target = target
  }

  public func perform() async throws -> some IntentResult {
    let route = HarnessMonitorDeepLinkRoute.pullRequest(id: target.id)
    if let url = HarnessMonitorDeepLinkRouter.url(for: route) {
      await MainActor.run {
        _ = NSWorkspace.shared.open(url)
      }
    }
    return .result()
  }
}
