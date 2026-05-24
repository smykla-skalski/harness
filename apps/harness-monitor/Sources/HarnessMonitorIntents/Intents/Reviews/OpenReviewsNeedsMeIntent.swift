import AppIntents
import AppKit
import Foundation
import HarnessMonitorKit

public struct OpenReviewsNeedsMeIntent: AppIntent {
  public static var title: LocalizedStringResource { "Open Pull Requests Needing My Review" }
  public static var description: IntentDescription {
    IntentDescription(
      "Bring Harness Monitor to the front filtered to pull requests waiting on your review",
      categoryName: "Reviews",
      searchKeywords: ["needs me", "needs review", "to review", "review queue"]
    )
  }
  public static var openAppWhenRun: Bool { true }

  public init() {}

  public func perform() async throws -> some IntentResult {
    if let url = HarnessMonitorDeepLinkRouter.url(for: .reviews(needsMeOn: true)) {
      await MainActor.run {
        _ = NSWorkspace.shared.open(url)
      }
    }
    return .result()
  }
}
