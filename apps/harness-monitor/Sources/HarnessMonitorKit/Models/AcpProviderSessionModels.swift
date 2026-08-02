import Foundation

/// One provider-owned ACP session returned by `session/list`
///
/// These identifiers do not identify a Harness workspace or managed agent
public struct AcpProviderSession: Codable, Equatable, Identifiable, Sendable {
  public let sessionID: String
  public let cwd: String
  public let additionalDirectories: [String]
  public let title: String?
  public let updatedAt: String?

  public var id: String { sessionID }

  public init(
    sessionID: String,
    cwd: String,
    additionalDirectories: [String] = [],
    title: String? = nil,
    updatedAt: String? = nil
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.additionalDirectories = additionalDirectories
    self.title = title
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case cwd
    case additionalDirectories = "additional_directories"
    case title
    case updatedAt = "updated_at"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    cwd = try container.decode(String.self, forKey: .cwd)
    additionalDirectories =
      try container.decodeIfPresent(
        [String].self,
        forKey: .additionalDirectories
      ) ?? []
    title = try container.decodeIfPresent(String.self, forKey: .title)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
  }
}

public struct AcpProviderSessionPage: Codable, Equatable, Sendable {
  public let sessions: [AcpProviderSession]
  public let nextCursor: String?

  public init(sessions: [AcpProviderSession], nextCursor: String? = nil) {
    self.sessions = sessions
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case sessions
    case nextCursor = "next_cursor"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessions = try container.decodeIfPresent([AcpProviderSession].self, forKey: .sessions) ?? []
    nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
  }
}

struct AcpMutationAcknowledgement: Codable {
  let ok: Bool
}
