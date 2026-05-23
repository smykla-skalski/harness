import Foundation

struct DashboardReviewsAuthorOrdering {
  let configuredAuthors: [String]

  func compare(_ lhs: String, _ rhs: String) -> Bool {
    sortKey(for: lhs) < sortKey(for: rhs)
  }

  private func sortKey(for author: String) -> DashboardReviewsAuthorSortKey {
    if let index = configuredAuthors.firstIndex(of: author) {
      return DashboardReviewsAuthorSortKey(bucket: 0, configuredIndex: index, author: author)
    }
    return DashboardReviewsAuthorSortKey(
      bucket: 1,
      configuredIndex: Int.max,
      author: author
    )
  }
}

struct DashboardReviewsAuthorSortKey: Comparable {
  let bucket: Int
  let configuredIndex: Int
  let author: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.bucket != rhs.bucket {
      return lhs.bucket < rhs.bucket
    }
    if lhs.configuredIndex != rhs.configuredIndex {
      return lhs.configuredIndex < rhs.configuredIndex
    }
    return lhs.author.localizedStandardCompare(rhs.author) == .orderedAscending
  }
}
