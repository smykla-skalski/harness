import Foundation
import OSLog

enum DashboardReviewsTextPasteTrace {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  struct Interval: Sendable {
    let name: StaticString
    let state: OSSignpostIntervalState
  }

  static func beginHandle(textLength: Int) -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.handle",
      id: signposter.makeSignpostID(),
      "chars=\(textLength, privacy: .public)"
    )
    return Interval(name: "reviews_text_paste.handle", state: state)
  }

  static func beginPreparePolicyRuntime() -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.prepare_policy_runtime",
      id: signposter.makeSignpostID()
    )
    return Interval(name: "reviews_text_paste.prepare_policy_runtime", state: state)
  }

  static func beginParseReferences(textLength: Int) -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.parse_references",
      id: signposter.makeSignpostID(),
      "chars=\(textLength, privacy: .public)"
    )
    return Interval(name: "reviews_text_paste.parse_references", state: state)
  }

  static func beginPolicyExecute(referenceCount: Int) -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.policy_execute",
      id: signposter.makeSignpostID(),
      "references=\(referenceCount, privacy: .public)"
    )
    return Interval(name: "reviews_text_paste.policy_execute", state: state)
  }

  static func beginResolveReferences(referenceCount: Int) -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.resolve_references",
      id: signposter.makeSignpostID(),
      "references=\(referenceCount, privacy: .public)"
    )
    return Interval(name: "reviews_text_paste.resolve_references", state: state)
  }

  static func beginFetchRepositories(repositoryCount: Int) -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.fetch_repositories",
      id: signposter.makeSignpostID(),
      "repositories=\(repositoryCount, privacy: .public)"
    )
    return Interval(name: "reviews_text_paste.fetch_repositories", state: state)
  }

  static func beginResolvePullRequests(referenceCount: Int) -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.resolve_pull_requests",
      id: signposter.makeSignpostID(),
      "references=\(referenceCount, privacy: .public)"
    )
    return Interval(name: "reviews_text_paste.resolve_pull_requests", state: state)
  }

  static func beginPreviewApproval(itemCount: Int) -> Interval {
    let state = signposter.beginInterval(
      "reviews_text_paste.preview_approval",
      id: signposter.makeSignpostID(),
      "items=\(itemCount, privacy: .public)"
    )
    return Interval(name: "reviews_text_paste.preview_approval", state: state)
  }

  static func end(_ interval: Interval) {
    signposter.endInterval(interval.name, interval.state)
  }
}
