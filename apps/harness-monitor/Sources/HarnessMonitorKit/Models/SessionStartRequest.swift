import Foundation

public struct SessionStartRequest: Codable, Equatable, Sendable {
  public let title: String
  public let context: String
  public let sessionId: String?
  public let projectDir: String
  public let policyPreset: String?
  public let baseRef: String?

  public init(
    title: String,
    context: String,
    sessionId: String?,
    projectDir: String,
    policyPreset: String?,
    baseRef: String?
  ) {
    self.title = title
    self.context = context
    self.sessionId = sessionId
    self.projectDir = projectDir
    self.policyPreset = policyPreset
    self.baseRef = baseRef
  }

  public enum CodingKeys: String, CodingKey {
    case title, context, sessionId, projectDir, policyPreset, baseRef
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(title, forKey: .title)
    try container.encode(context, forKey: .context)
    try container.encodeIfPresent(sessionId, forKey: .sessionId)
    try container.encode(projectDir, forKey: .projectDir)
    try container.encodeIfPresent(policyPreset, forKey: .policyPreset)
    try container.encodeIfPresent(baseRef, forKey: .baseRef)
  }
}

public struct SessionStartResult: Equatable, Sendable {
  public let sessionId: String

  public init(sessionId: String) {
    self.sessionId = sessionId
  }
}

struct SessionStartMutationResponse: Decodable, Sendable {
  struct State: Decodable, Sendable {
    let sessionId: String

    // The daemon returns the full session state object; the app only needs its id. Pin the snake
    // key so this minimal extractor decodes through the plain wire decoder too.
    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
    }
  }

  let state: State

  var result: SessionStartResult {
    SessionStartResult(sessionId: state.sessionId)
  }
}
