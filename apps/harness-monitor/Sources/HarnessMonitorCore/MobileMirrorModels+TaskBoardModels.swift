import Foundation

public struct MobileTaskBoardSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var title: String
  public var bodyPreview: String
  public var status: String
  public var statusTitle: String
  public var priority: String
  public var priorityTitle: String
  public var tags: [String]
  public var projectID: String?
  public var sessionID: String?
  public var workItemID: String?
  public var agentMode: String
  public var needsYou: Bool
  public var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id
    case stationID
    case title
    case bodyPreview
    case status
    case statusTitle
    case priority
    case priorityTitle
    case tags
    case projectID
    case sessionID
    case workItemID
    case agentMode
    case needsYou
    case updatedAt
  }

  public init(
    id: String,
    stationID: String,
    title: String,
    bodyPreview: String,
    status: String,
    statusTitle: String,
    priority: String,
    priorityTitle: String,
    tags: [String] = [],
    projectID: String? = nil,
    sessionID: String? = nil,
    workItemID: String? = nil,
    agentMode: String,
    needsYou: Bool,
    updatedAt: Date
  ) {
    let canonicalStatus = Self.canonicalStatus(status)
    self.id = id
    self.stationID = stationID
    self.title = title
    self.bodyPreview = bodyPreview
    self.status = canonicalStatus
    self.statusTitle = Self.canonicalStatusTitle(
      sourceStatus: status,
      statusTitle: statusTitle
    )
    self.priority = priority
    self.priorityTitle = priorityTitle
    self.tags = tags
    self.projectID = projectID
    self.sessionID = sessionID
    self.workItemID = workItemID
    self.agentMode = agentMode
    self.needsYou = needsYou
    self.updatedAt = updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      stationID: try container.decode(String.self, forKey: .stationID),
      title: try container.decode(String.self, forKey: .title),
      bodyPreview: try container.decode(String.self, forKey: .bodyPreview),
      status: try container.decode(String.self, forKey: .status),
      statusTitle: try container.decode(String.self, forKey: .statusTitle),
      priority: try container.decode(String.self, forKey: .priority),
      priorityTitle: try container.decode(String.self, forKey: .priorityTitle),
      tags: try container.decode([String].self, forKey: .tags),
      projectID: try container.decodeIfPresent(String.self, forKey: .projectID),
      sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID),
      workItemID: try container.decodeIfPresent(String.self, forKey: .workItemID),
      agentMode: try container.decode(String.self, forKey: .agentMode),
      needsYou: try container.decode(Bool.self, forKey: .needsYou),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    let canonicalStatus = Self.canonicalStatus(status)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(stationID, forKey: .stationID)
    try container.encode(title, forKey: .title)
    try container.encode(bodyPreview, forKey: .bodyPreview)
    try container.encode(canonicalStatus, forKey: .status)
    try container.encode(
      Self.canonicalStatusTitle(sourceStatus: status, statusTitle: statusTitle),
      forKey: .statusTitle
    )
    try container.encode(priority, forKey: .priority)
    try container.encode(priorityTitle, forKey: .priorityTitle)
    try container.encode(tags, forKey: .tags)
    try container.encodeIfPresent(projectID, forKey: .projectID)
    try container.encodeIfPresent(sessionID, forKey: .sessionID)
    try container.encodeIfPresent(workItemID, forKey: .workItemID)
    try container.encode(agentMode, forKey: .agentMode)
    try container.encode(needsYou, forKey: .needsYou)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  public func commandDraft(
    kind: MobileCommandKind,
    targetRevision: Int64,
    status nextStatus: String? = nil,
    expiresAfter: TimeInterval = 15 * 60
  ) -> MobileCommandDraft {
    var payload = commandPayload
    if let nextStatus = trimmedPayloadValue(nextStatus) {
      payload["status"] = nextStatus
    }
    return MobileCommandDraft(
      kind: kind,
      confirmationText: confirmationText(for: kind, nextStatus: nextStatus),
      target: MobileCommandTarget(
        stationID: stationID,
        sessionID: trimmedPayloadValue(sessionID),
        taskID: id,
        targetRevision: targetRevision
      ),
      payload: payload,
      expiresAfter: expiresAfter
    )
  }

  public var commandPayload: [String: String] {
    var payload: [String: String] = [
      "itemID": id,
      "status": Self.canonicalStatus(status),
      "priority": priority,
      "agentMode": agentMode,
    ]
    payload["projectID"] = trimmedPayloadValue(projectID)
    payload["sessionID"] = trimmedPayloadValue(sessionID)
    payload["workItemID"] = trimmedPayloadValue(workItemID)
    return payload
  }

  private func confirmationText(for kind: MobileCommandKind, nextStatus: String?) -> String {
    switch kind {
    case .taskBoardPlanApproval:
      return String(localized: "Approve plan for \(title)", bundle: .module)
    case .taskBoardDispatch:
      if let nextStatus = trimmedPayloadValue(nextStatus) {
        return String(localized: "Move \(title) to \(nextStatus)", bundle: .module)
      }
      return String(localized: "Dispatch \(title)", bundle: .module)
    case .refresh:
      return String(localized: "Refresh task board item \(title)", bundle: .module)
    default:
      return String(localized: "\(kind.title) for \(title)", bundle: .module)
    }
  }

  private func trimmedPayloadValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func canonicalStatus(_ status: String) -> String {
    status == "umbrella" ? "backlog" : status
  }

  private static func canonicalStatusTitle(
    sourceStatus: String,
    statusTitle: String
  ) -> String {
    if sourceStatus == "umbrella"
      || (sourceStatus == "backlog" && statusTitle == "Umbrella")
    {
      return "Backlog"
    }
    return statusTitle
  }
}
