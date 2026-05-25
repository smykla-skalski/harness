import Foundation
import HarnessMonitorKit

public enum DashboardReviewsDetailMode: String, Hashable, Sendable {
  case overview
  case files
}

public struct DashboardReviewsHistorySelection: Hashable, Sendable {
  public let selectedPullRequestIDs: [String]
  public let primaryPullRequestID: String
  public let detailMode: DashboardReviewsDetailMode
  public let selectedFilePath: String?
  public let lineSelection: ReviewLineSelection?

  public init(
    selectedPullRequestIDs: [String],
    primaryPullRequestID: String,
    detailMode: DashboardReviewsDetailMode,
    selectedFilePath: String? = nil,
    lineSelection: ReviewLineSelection? = nil
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
    let resolvedDetailMode = normalizedIDs.isEmpty ? .overview : normalizedDetailMode
    self.selectedPullRequestIDs = normalizedIDs
    self.primaryPullRequestID = normalizedIDs.isEmpty ? "" : normalizedPrimary
    self.detailMode = resolvedDetailMode
    // A file/line target is only meaningful inside the Files detail mode; drop
    // it otherwise so history entries compare equal across overview toggles.
    let resolvedPath =
      resolvedDetailMode == .files
      ? selectedFilePath.flatMap { $0.isEmpty ? nil : $0 }
      : nil
    self.selectedFilePath = resolvedPath
    self.lineSelection = resolvedPath == nil ? nil : lineSelection
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
