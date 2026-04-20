import Foundation

public struct SessionStartRequest: Codable, Equatable, Sendable {
  public let title: String
  public let context: String
  public let runtime: String
  public let sessionId: String?
  public let projectDir: String
  public let policyPreset: String?
  public let baseRef: String?

  public init(
    title: String,
    context: String,
    runtime: String,
    sessionId: String?,
    projectDir: String,
    policyPreset: String?,
    baseRef: String?
  ) {
    self.title = title
    self.context = context
    self.runtime = runtime
    self.sessionId = sessionId
    self.projectDir = projectDir
    self.policyPreset = policyPreset
    self.baseRef = baseRef
  }

  public enum CodingKeys: String, CodingKey {
    case title, context, runtime, sessionId, projectDir, policyPreset, baseRef
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(title, forKey: .title)
    try container.encode(context, forKey: .context)
    try container.encode(runtime, forKey: .runtime)
    try container.encodeIfPresent(sessionId, forKey: .sessionId)
    try container.encode(projectDir, forKey: .projectDir)
    try container.encodeIfPresent(policyPreset, forKey: .policyPreset)
    try container.encodeIfPresent(baseRef, forKey: .baseRef)
  }
}
