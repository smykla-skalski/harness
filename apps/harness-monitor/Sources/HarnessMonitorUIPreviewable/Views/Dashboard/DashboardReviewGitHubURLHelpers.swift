import CryptoKit
import Foundation

func dashboardReviewFileName(for path: String) -> String {
  path.split(separator: "/").last.map(String.init) ?? path
}

func dashboardReviewFileBlobURL(
  repositoryFullName: String?,
  headRefOid: String,
  path: String
) -> URL? {
  guard
    let repositoryFullName,
    !repositoryFullName.isEmpty,
    !headRefOid.isEmpty
  else {
    return nil
  }
  let encodedPath = path.dashboardReviewGitHubPathEncoded
  return URL(string: "https://github.com/\(repositoryFullName)/blob/\(headRefOid)/\(encodedPath)")
}

func dashboardReviewPullRequestFileURL(
  repositoryFullName: String?,
  pullRequestNumber: UInt64?,
  path: String
) -> URL? {
  guard
    let repositoryFullName,
    !repositoryFullName.isEmpty,
    let pullRequestNumber
  else {
    return nil
  }
  let anchor = dashboardReviewPullRequestFileAnchor(for: path)
  return URL(string: "https://github.com/\(repositoryFullName)/pull/\(pullRequestNumber)/files#\(anchor)")
}

func dashboardReviewCopyFilenamesMenuTitle(itemCount: Int) -> String {
  itemCount == 1 ? "Copy Filename" : "Copy \(itemCount) Filenames"
}

func dashboardReviewCopyPathsMenuTitle(itemCount: Int) -> String {
  itemCount == 1 ? "Copy Full Path" : "Copy \(itemCount) Full Paths"
}

func dashboardReviewCopyGitHubLinksMenuTitle(itemCount: Int) -> String {
  itemCount == 1 ? "Copy GitHub Link" : "Copy \(itemCount) GitHub Links"
}

func dashboardReviewOpenGitHubLinksMenuTitle(itemCount: Int) -> String {
  itemCount == 1 ? "Open on GitHub" : "Open \(itemCount) Files on GitHub"
}

func dashboardReviewCopyPullRequestFileLinksMenuTitle(itemCount: Int) -> String {
  itemCount == 1 ? "Copy Pull Request File Link" : "Copy \(itemCount) Pull Request File Links"
}

private func dashboardReviewPullRequestFileAnchor(for path: String) -> String {
  "diff-\(dashboardReviewSHA256Hex(of: path))"
}

private func dashboardReviewSHA256Hex(of input: String) -> String {
  let digest = SHA256.hash(data: Data(input.utf8))
  return digest.map { String(format: "%02x", $0) }.joined()
}

extension String {
  var dashboardReviewGitHubPathEncoded: String {
    var encoded = ""
    encoded.reserveCapacity(count)
    var segmentStart = startIndex
    var current = startIndex
    while current < endIndex {
      if self[current] == "/" {
        appendEncodedGitHubPathSegment(segmentStart..<current, to: &encoded)
        encoded.append("/")
        segmentStart = index(after: current)
      }
      current = index(after: current)
    }
    appendEncodedGitHubPathSegment(segmentStart..<endIndex, to: &encoded)
    return encoded
  }

  private func appendEncodedGitHubPathSegment(
    _ range: Range<String.Index>,
    to encoded: inout String
  ) {
    guard !range.isEmpty else { return }
    let segment = String(self[range])
    encoded.append(
      contentsOf: segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    )
  }
}
