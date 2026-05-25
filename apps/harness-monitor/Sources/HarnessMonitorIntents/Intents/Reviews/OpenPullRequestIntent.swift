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
    if let url = Self.deepLinkURL(for: target) {
      await MainActor.run {
        _ = NSWorkspace.shared.open(url)
      }
    }
    return .result()
  }

  /// Resolve the `harness://` URL for `target`. The deep-link id is built from
  /// the entity's repository and number; `id` is the opaque GitHub node id and
  /// is not a valid deep-link id.
  static func deepLinkURL(for target: PullRequestEntity) -> URL? {
    let number = target.number > 0 ? UInt64(target.number) : 0
    let deepLinkID = HarnessMonitorDeepLinkRouter.pullRequestDeepLinkID(
      repositoryFullName: target.repository,
      number: number
    )
    return HarnessMonitorDeepLinkRouter.url(
      for: .pullRequest(id: deepLinkID ?? target.id, file: nil)
    )
  }
}
