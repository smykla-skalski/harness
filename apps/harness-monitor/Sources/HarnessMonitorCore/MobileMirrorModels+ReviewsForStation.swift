import Foundation

extension MobileMirrorSnapshot {
  /// Mirrored reviews for the given station (empty station id means all stations),
  /// ordered so the ones that need you come first, then most recently updated. Used
  /// by the watch reviews list so a pull request stays reachable after it drops off
  /// the live "Needs You" attention list.
  public func reviews(forStation stationID: String) -> [MobileReviewSummary] {
    reviews
      .filter { stationID.isEmpty || $0.stationID == stationID }
      .sorted { lhs, rhs in
        if lhs.needsYou != rhs.needsYou {
          return lhs.needsYou && !rhs.needsYou
        }
        return lhs.updatedAt > rhs.updatedAt
      }
  }
}
