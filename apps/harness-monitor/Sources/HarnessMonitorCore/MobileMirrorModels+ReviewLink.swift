import Foundation

extension MobileAttentionItem {
  /// Review id to open when this attention item is a pull-request review that is
  /// still present in the mirrored review list; nil otherwise (non-review kinds,
  /// missing target, or a review that is no longer mirrored)
  public func navigableReviewID(in reviews: [MobileReviewSummary]) -> String? {
    guard kind == .pullRequest, let reviewID = target?.reviewID,
      reviews.contains(where: { $0.id == reviewID })
    else {
      return nil
    }
    return reviewID
  }
}
