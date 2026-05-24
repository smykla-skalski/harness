import Foundation

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
