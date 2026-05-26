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
    self.id = id
    self.stationID = stationID
    self.title = title
    self.bodyPreview = bodyPreview
    self.status = status
    self.statusTitle = statusTitle
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
      "status": status,
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
}
