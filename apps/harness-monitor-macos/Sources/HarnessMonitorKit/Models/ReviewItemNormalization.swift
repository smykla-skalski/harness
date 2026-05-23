import Foundation

func normalizedReviewItems(
  _ items: [ReviewItem]
) -> [ReviewItem] {
  guard items.count > 1 else { return items }
  let formatter = ISO8601DateFormatter()
  var uniqueItems: [ReviewItem] = []
  uniqueItems.reserveCapacity(items.count)
  var indexByPullRequestID: [String: Int] = [:]

  for item in items {
    if let existingIndex = indexByPullRequestID[item.pullRequestID] {
      let existingItem = uniqueItems[existingIndex]
      if reviewItem(item, shouldReplace: existingItem, using: formatter) {
        uniqueItems[existingIndex] = item
      }
      continue
    }

    indexByPullRequestID[item.pullRequestID] = uniqueItems.count
    uniqueItems.append(item)
  }

  return uniqueItems
}

private func reviewItem(
  _ candidate: ReviewItem,
  shouldReplace existing: ReviewItem,
  using formatter: ISO8601DateFormatter
) -> Bool {
  let candidateDate = formatter.date(from: candidate.updatedAt)
  let existingDate = formatter.date(from: existing.updatedAt)

  switch (candidateDate, existingDate) {
  case (let candidateDate?, let existingDate?) where candidateDate != existingDate:
    return candidateDate > existingDate
  case (_?, nil):
    return true
  case (nil, _?):
    return false
  default:
    return candidate.updatedAt >= existing.updatedAt
  }
}
