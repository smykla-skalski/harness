import Foundation

enum TaskBoardReviewGitHubLinks {
  static func pullRequest(repository: String?, number: UInt64?) -> URL? {
    guard let repository, let number else { return nil }
    return githubURL(path: "/\(repository)/pull/\(number)")
  }

  static func revision(repository: String?, revision: String?) -> URL? {
    guard let repository, let revision, !revision.isEmpty else { return nil }
    return githubURL(path: "/\(repository)/commit/\(revision)")
  }

  static func file(
    repository: String,
    revision: String,
    path: String,
    line: UInt32?
  ) -> URL? {
    guard !repository.isEmpty, !revision.isEmpty, !path.isEmpty else { return nil }
    return githubURL(
      path: "/\(repository)/blob/\(revision)/\(path)",
      fragment: line.map { "L\($0)" }
    )
  }

  private static func githubURL(path: String, fragment: String? = nil) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = path
    components.fragment = fragment
    return components.url
  }
}
