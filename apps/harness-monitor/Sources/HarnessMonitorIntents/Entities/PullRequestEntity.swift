import AppIntents
import Foundation
import HarnessMonitorKit

public struct PullRequestEntity: AppEntity, Identifiable, Sendable {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Pull Request", numericFormat: "\(placeholder: .int) pull requests")
  }

  public static var defaultQuery: PullRequestQuery { PullRequestQuery() }

  public let id: String
  public let title: String
  public let repository: String
  public let number: Int
  public let authorLogin: String?
  public let state: PullRequestStateEnum
  public let reviewerSummary: String
  public let lastUpdated: Date?
  public let url: URL?

  public init(
    id: String,
    title: String,
    repository: String,
    number: Int,
    authorLogin: String?,
    state: PullRequestStateEnum,
    reviewerSummary: String,
    lastUpdated: Date?,
    url: URL?
  ) {
    self.id = id
    self.title = title
    self.repository = repository
    self.number = number
    self.authorLogin = authorLogin
    self.state = state
    self.reviewerSummary = reviewerSummary
    self.lastUpdated = lastUpdated
    self.url = url
  }

  public init(from item: ReviewItem) {
    let trimmedAuthor = item.authorLogin.trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      id: item.pullRequestID,
      title: item.title,
      repository: item.repository,
      number: Int(item.number),
      authorLogin: trimmedAuthor.isEmpty ? nil : trimmedAuthor,
      state: PullRequestStateEnum(reviewState: item.state, isDraft: item.isDraft),
      reviewerSummary: PullRequestReviewerSummary(reviews: item.reviews).label,
      lastUpdated: Self.parseISO8601(item.updatedAt),
      url: URL(string: item.url)
    )
  }

  public var displayRepresentation: DisplayRepresentation {
    let titleString = "\(repository) #\(number)"
    let subtitle = LocalizedStringResource(stringLiteral: title)
    return DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: titleString),
      subtitle: subtitle
    )
  }

  static func parseISO8601(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let date = iso8601WithFractional.date(from: trimmed) {
      return date
    }
    return iso8601Plain.date(from: trimmed)
  }

  nonisolated(unsafe) private static let iso8601WithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}
