import Foundation

enum DashboardReviewsDetailMode: String {
  case overview
  case files
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
