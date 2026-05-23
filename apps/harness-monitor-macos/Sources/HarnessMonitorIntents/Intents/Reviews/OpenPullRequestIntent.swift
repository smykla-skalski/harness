import AppIntents
import AppKit
import Foundation
import HarnessMonitorKit

public struct OpenPullRequestIntent: AppIntent {
  public static var title: LocalizedStringResource { "Open Pull Request" }
  public static var description: IntentDescription {
    IntentDescription(
      "Bring Harness Monitor to the front with this pull request selected in Reviews.",
      categoryName: "Reviews",
      searchKeywords: ["pull request", "pr", "open", "review"]
    )
  }
  public static var openAppWhenRun: Bool { true }

  @Parameter(title: "Pull Request")
  public var pullRequest: PullRequestEntity

  public init() {}

  public init(pullRequest: PullRequestEntity) {
    self.pullRequest = pullRequest
  }

  public func perform() async throws -> some IntentResult {
    let route = HarnessMonitorDeepLinkRoute.pullRequest(id: pullRequest.id)
    if let url = HarnessMonitorDeepLinkRouter.url(for: route) {
      await MainActor.run {
        _ = NSWorkspace.shared.open(url)
      }
    }
    return .result()
  }
}
