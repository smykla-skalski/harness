import Foundation

struct DashboardReviewsPinnedRepositories: Codable, Equatable {
  static let storageKey = "dashboard.reviews.pinned-repositories"

  var repositoryIDs: [String] = []

  init(repositoryIDs: [String] = []) {
    self.repositoryIDs = repositoryIDs
  }

  init(storedValue: String) {
    self = Self.decode(from: storedValue)
  }

  var encodedString: String {
    DashboardReviewsStorageCodec.encodeToString(self)
  }

  func contains(_ repositoryID: String) -> Bool {
    repositoryIDs.contains(repositoryID)
  }

  @discardableResult
  mutating func pin(_ repositoryID: String) -> Bool {
    guard !contains(repositoryID) else { return false }
    repositoryIDs.append(repositoryID)
    return true
  }

  @discardableResult
  mutating func unpin(_ repositoryID: String) -> Bool {
    guard let index = repositoryIDs.firstIndex(of: repositoryID) else {
      return false
    }
    repositoryIDs.remove(at: index)
    return true
  }

  static func decode(from string: String) -> Self {
    DashboardReviewsStorageCodec.decode(Self.self, from: string) ?? Self()
  }
}
