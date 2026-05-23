import Foundation

public struct ReviewsAvatarRequest: Codable, Equatable, Sendable {
  public let avatarURL: String

  public init(avatarURL: String) {
    self.avatarURL = avatarURL
  }

  enum CodingKeys: String, CodingKey {
    case avatarURL = "avatarUrl"
  }
}

public struct ReviewsAvatarResponse: Codable, Equatable, Sendable {
  public let avatarURL: String
  public let mimeType: String
  public let contentBase64: String
  public let fetchedAt: String

  public init(
    avatarURL: String,
    mimeType: String,
    contentBase64: String,
    fetchedAt: String
  ) {
    self.avatarURL = avatarURL
    self.mimeType = mimeType
    self.contentBase64 = contentBase64
    self.fetchedAt = fetchedAt
  }

  public var contentData: Data? {
    Data(base64Encoded: contentBase64)
  }

  enum CodingKeys: String, CodingKey {
    case avatarURL = "avatarUrl"
    case mimeType
    case contentBase64
    case fetchedAt
  }
}
