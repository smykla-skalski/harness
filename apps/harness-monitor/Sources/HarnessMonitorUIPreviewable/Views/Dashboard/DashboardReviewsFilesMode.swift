import Foundation

public enum DashboardReviewsDetailMode: String, Hashable, Sendable {
  case overview
  case files
}

public struct DashboardReviewsHistorySelection: Hashable, Sendable {
  public let selectedPullRequestIDs: [String]
  public let primaryPullRequestID: String
  public let detailMode: DashboardReviewsDetailMode

  public init(
    selectedPullRequestIDs: [String],
    primaryPullRequestID: String,
    detailMode: DashboardReviewsDetailMode
  ) {
    let normalizedIDs = Array(Set(selectedPullRequestIDs)).sorted()
    let normalizedPrimary =
      normalizedIDs.contains(primaryPullRequestID)
      ? primaryPullRequestID
      : (normalizedIDs.first ?? "")
    let normalizedDetailMode =
      normalizedIDs.count == 1
      ? detailMode
      : .overview
    self.selectedPullRequestIDs = normalizedIDs
    self.primaryPullRequestID = normalizedIDs.isEmpty ? "" : normalizedPrimary
    self.detailMode = normalizedIDs.isEmpty ? .overview : normalizedDetailMode
  }

  var selectedPullRequestIDSet: Set<String> {
    Set(selectedPullRequestIDs)
  }
}

struct DashboardReviewsFileSelectionStorage: Codable, Equatable {
  var selectedPathByPullRequestID: [String: String] = [:]

  static func decode(_ raw: String) -> Self {
    guard let data = raw.data(using: .utf8) else { return Self() }
    return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
  }

  func encoded() -> String {
    guard let data = try? JSONEncoder().encode(self) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  mutating func remember(path: String?, for pullRequestID: String) {
    if let path, !path.isEmpty {
      selectedPathByPullRequestID[pullRequestID] = path
    } else {
      selectedPathByPullRequestID.removeValue(forKey: pullRequestID)
    }
  }

  func rememberedPath(for pullRequestID: String) -> String? {
    selectedPathByPullRequestID[pullRequestID]
  }
}
