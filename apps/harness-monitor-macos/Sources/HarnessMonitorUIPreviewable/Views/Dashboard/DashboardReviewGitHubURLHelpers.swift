import Foundation

extension String {
  var dashboardReviewGitHubPathEncoded: String {
    split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
      .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
      .joined(separator: "/")
  }
}
