import Foundation

public enum MobileStationState: String, Codable, CaseIterable, Sendable {
  case online
  case stale
  case offline

  public var title: String {
    switch self {
    case .online: "Online"
    case .stale: "Stale"
    case .offline: "Offline"
    }
  }
}

public enum MobileAttentionSeverity: String, Codable, CaseIterable, Sendable {
  case info
  case warning
  case critical

  public var rank: Int {
    switch self {
    case .critical: 0
    case .warning: 1
    case .info: 2
    }
  }

  public var title: String {
    switch self {
    case .info: "Info"
    case .warning: "Warning"
    case .critical: "Critical"
    }
  }
}

public enum MobileAttentionKind: String, Codable, CaseIterable, Sendable {
  case acpDecision
  case pullRequest
  case taskBoard
  case blockedAgent
  case commandFailure
  case stationHealth

  public var title: String {
    switch self {
    case .acpDecision: "ACP Decision"
    case .pullRequest: "Pull Request"
    case .taskBoard: "Task Board"
    case .blockedAgent: "Blocked Agent"
    case .commandFailure: "Command Failure"
    case .stationHealth: "Station Health"
    }
  }
}

public enum MobileCommandKind: String, Codable, CaseIterable, Sendable {
  case acpPermissionDecision
  case taskBoardDispatch
  case taskBoardPlanApproval
  case agentStart
  case agentStop
  case agentPrompt
  case pullRequestApprove
  case pullRequestLabel
  case pullRequestRerunChecks
  case pullRequestMerge
  case refresh

  public var title: String {
    switch self {
    case .acpPermissionDecision: "Resolve Permission"
    case .taskBoardDispatch: "Dispatch Task"
    case .taskBoardPlanApproval: "Approve Plan"
    case .agentStart: "Start Agent"
    case .agentStop: "Stop Agent"
    case .agentPrompt: "Prompt Agent"
    case .pullRequestApprove: "Approve PR"
    case .pullRequestLabel: "Label PR"
    case .pullRequestRerunChecks: "Rerun Checks"
    case .pullRequestMerge: "Merge PR"
    case .refresh: "Refresh"
    }
  }
}

public enum MobileCommandRisk: String, Codable, CaseIterable, Sendable {
  case low
  case high
  case destructive

  public var requiresFreshState: Bool {
    self != .low
  }
}

public enum MobileCommandStatus: String, Codable, CaseIterable, Sendable {
  case draft
  case queued
  case accepted
  case running
  case succeeded
  case failed
  case expired
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .expired, .cancelled:
      true
    case .draft, .queued, .accepted, .running:
      false
    }
  }

  public var title: String {
    switch self {
    case .draft: "Draft"
    case .queued: "Queued"
    case .accepted: "Accepted"
    case .running: "Running"
    case .succeeded: "Succeeded"
    case .failed: "Failed"
    case .expired: "Expired"
    case .cancelled: "Cancelled"
    }
  }
}

public struct MobileStationSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var displayName: String
  public var state: MobileStationState
  public var lastSeenAt: Date
  public var activeSessionCount: Int
  public var needsYouCount: Int
  public var commandQueueCount: Int
  public var defaultStation: Bool

  public init(
    id: String,
    displayName: String,
    state: MobileStationState,
    lastSeenAt: Date,
    activeSessionCount: Int,
    needsYouCount: Int,
    commandQueueCount: Int,
    defaultStation: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.state = state
    self.lastSeenAt = lastSeenAt
    self.activeSessionCount = activeSessionCount
    self.needsYouCount = needsYouCount
    self.commandQueueCount = commandQueueCount
    self.defaultStation = defaultStation
  }
}

public struct MobileAttentionItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var kind: MobileAttentionKind
  public var severity: MobileAttentionSeverity
  public var title: String
  public var subtitle: String
  public var updatedAt: Date
  public var commandKind: MobileCommandKind?
  public var target: MobileCommandTarget?
  public var commandPayload: [String: String]

  public init(
    id: String,
    stationID: String,
    kind: MobileAttentionKind,
    severity: MobileAttentionSeverity,
    title: String,
    subtitle: String,
    updatedAt: Date,
    commandKind: MobileCommandKind? = nil,
    target: MobileCommandTarget? = nil,
    commandPayload: [String: String] = [:]
  ) {
    self.id = id
    self.stationID = stationID
    self.kind = kind
    self.severity = severity
    self.title = title
    self.subtitle = subtitle
    self.updatedAt = updatedAt
    self.commandKind = commandKind
    self.target = target
    self.commandPayload = commandPayload
  }

  public var needsUserAction: Bool {
    severity != .info
  }
}

public struct MobileSessionSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var projectName: String
  public var title: String
  public var branch: String
  public var status: String
  public var activeAgentCount: Int
  public var blockedAgentCount: Int
  public var lastActivityAt: Date
  public var summary: String
  public var agents: [MobileAgentSummary]

  public init(
    id: String,
    stationID: String,
    projectName: String,
    title: String,
    branch: String,
    status: String,
    activeAgentCount: Int,
    blockedAgentCount: Int,
    lastActivityAt: Date,
    summary: String,
    agents: [MobileAgentSummary] = []
  ) {
    self.id = id
    self.stationID = stationID
    self.projectName = projectName
    self.title = title
    self.branch = branch
    self.status = status
    self.activeAgentCount = activeAgentCount
    self.blockedAgentCount = blockedAgentCount
    self.lastActivityAt = lastActivityAt
    self.summary = summary
    self.agents = agents
  }

  enum CodingKeys: String, CodingKey {
    case id
    case stationID
    case projectName
    case title
    case branch
    case status
    case activeAgentCount
    case blockedAgentCount
    case lastActivityAt
    case summary
    case agents
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      stationID: try container.decode(String.self, forKey: .stationID),
      projectName: try container.decode(String.self, forKey: .projectName),
      title: try container.decode(String.self, forKey: .title),
      branch: try container.decode(String.self, forKey: .branch),
      status: try container.decode(String.self, forKey: .status),
      activeAgentCount: try container.decode(Int.self, forKey: .activeAgentCount),
      blockedAgentCount: try container.decode(Int.self, forKey: .blockedAgentCount),
      lastActivityAt: try container.decode(Date.self, forKey: .lastActivityAt),
      summary: try container.decode(String.self, forKey: .summary),
      agents: try container.decodeIfPresent([MobileAgentSummary].self, forKey: .agents) ?? []
    )
  }
}

public enum MobileAgentFamily: String, Codable, CaseIterable, Sendable {
  case terminal
  case codex
  case acp

  public var title: String {
    switch self {
    case .terminal: "Terminal"
    case .codex: "Codex"
    case .acp: "ACP"
    }
  }
}

public struct MobileAgentSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var sessionID: String
  public var displayName: String
  public var family: MobileAgentFamily
  public var status: String
  public var role: String?
  public var isActive: Bool
  public var isBlocked: Bool
  public var pendingApprovalCount: Int
  public var pendingPermissionCount: Int
  public var lastActivityAt: Date
  public var summary: String

  public init(
    id: String,
    stationID: String,
    sessionID: String,
    displayName: String,
    family: MobileAgentFamily,
    status: String,
    role: String? = nil,
    isActive: Bool,
    isBlocked: Bool,
    pendingApprovalCount: Int = 0,
    pendingPermissionCount: Int = 0,
    lastActivityAt: Date,
    summary: String = ""
  ) {
    self.id = id
    self.stationID = stationID
    self.sessionID = sessionID
    self.displayName = displayName
    self.family = family
    self.status = status
    self.role = role
    self.isActive = isActive
    self.isBlocked = isBlocked
    self.pendingApprovalCount = pendingApprovalCount
    self.pendingPermissionCount = pendingPermissionCount
    self.lastActivityAt = lastActivityAt
    self.summary = summary
  }

  public func promptDraft(
    prompt: String,
    targetRevision: Int64,
    expiresAfter: TimeInterval = 15 * 60
  ) -> MobileCommandDraft {
    MobileCommandDraft(
      kind: .agentPrompt,
      confirmationText: "Send prompt to \(displayName).",
      target: commandTarget(targetRevision: targetRevision),
      payload: ["prompt": prompt],
      expiresAfter: expiresAfter
    )
  }

  public func stopDraft(
    targetRevision: Int64,
    expiresAfter: TimeInterval = 15 * 60
  ) -> MobileCommandDraft {
    MobileCommandDraft(
      kind: .agentStop,
      confirmationText: "Stop \(displayName).",
      target: commandTarget(targetRevision: targetRevision),
      expiresAfter: expiresAfter
    )
  }

  private func commandTarget(targetRevision: Int64) -> MobileCommandTarget {
    MobileCommandTarget(
      stationID: stationID,
      sessionID: sessionID,
      agentID: id,
      targetRevision: targetRevision
    )
  }
}

public struct MobileReviewCheckSnippet: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var status: String
  public var conclusion: String
  public var checkSuiteID: String?
  public var detailsURL: String?

  public init(
    id: String,
    name: String,
    status: String,
    conclusion: String,
    checkSuiteID: String? = nil,
    detailsURL: String? = nil
  ) {
    self.id = id
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.checkSuiteID = checkSuiteID
    self.detailsURL = detailsURL
  }
}

public struct MobileReviewFileSnippet: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var path: String
  public var changeType: String
  public var additions: UInt32
  public var deletions: UInt32
  public var viewedState: String
  public var isBinary: Bool

  public init(
    id: String,
    path: String,
    changeType: String,
    additions: UInt32,
    deletions: UInt32,
    viewedState: String,
    isBinary: Bool
  ) {
    self.id = id
    self.path = path
    self.changeType = changeType
    self.additions = additions
    self.deletions = deletions
    self.viewedState = viewedState
    self.isBinary = isBinary
  }
}

public struct MobileReviewActivitySnippet: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var actor: String?
  public var summary: String
  public var recordedAt: Date

  public init(
    id: String,
    kind: String,
    actor: String? = nil,
    summary: String,
    recordedAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.actor = actor
    self.summary = summary
    self.recordedAt = recordedAt
  }
}

public struct MobileReviewSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var repositoryID: String?
  public var repository: String
  public var number: Int
  public var url: String?
  public var title: String
  public var author: String
  public var state: String
  public var checksSummary: String
  public var headSha: String?
  public var mergeable: String?
  public var reviewStatus: String?
  public var checkStatus: String?
  public var policyBlocked: Bool?
  public var isDraft: Bool?
  public var labels: [String]
  public var checks: [MobileReviewCheckSnippet]
  public var files: [MobileReviewFileSnippet]
  public var activity: [MobileReviewActivitySnippet]
  public var additions: UInt64
  public var deletions: UInt64
  public var requiredFailedCheckNames: [String]
  public var viewerCanUpdate: Bool
  public var viewerCanMergeAsAdmin: Bool
  public var filePaginationComplete: Bool?
  public var needsYou: Bool
  public var updatedAt: Date

  public init(
    id: String,
    stationID: String,
    repositoryID: String? = nil,
    repository: String,
    number: Int,
    url: String? = nil,
    title: String,
    author: String,
    state: String,
    checksSummary: String,
    headSha: String? = nil,
    mergeable: String? = nil,
    reviewStatus: String? = nil,
    checkStatus: String? = nil,
    policyBlocked: Bool? = nil,
    isDraft: Bool? = nil,
    labels: [String] = [],
    checks: [MobileReviewCheckSnippet] = [],
    files: [MobileReviewFileSnippet] = [],
    activity: [MobileReviewActivitySnippet] = [],
    additions: UInt64 = 0,
    deletions: UInt64 = 0,
    requiredFailedCheckNames: [String] = [],
    viewerCanUpdate: Bool = true,
    viewerCanMergeAsAdmin: Bool = false,
    filePaginationComplete: Bool? = nil,
    needsYou: Bool,
    updatedAt: Date
  ) {
    self.id = id
    self.stationID = stationID
    self.repositoryID = repositoryID
    self.repository = repository
    self.number = number
    self.url = url
    self.title = title
    self.author = author
    self.state = state
    self.checksSummary = checksSummary
    self.headSha = headSha
    self.mergeable = mergeable
    self.reviewStatus = reviewStatus
    self.checkStatus = checkStatus
    self.policyBlocked = policyBlocked
    self.isDraft = isDraft
    self.labels = labels
    self.checks = checks
    self.files = files
    self.activity = activity
    self.additions = additions
    self.deletions = deletions
    self.requiredFailedCheckNames = requiredFailedCheckNames
    self.viewerCanUpdate = viewerCanUpdate
    self.viewerCanMergeAsAdmin = viewerCanMergeAsAdmin
    self.filePaginationComplete = filePaginationComplete
    self.needsYou = needsYou
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case stationID
    case repositoryID
    case repository
    case number
    case url
    case title
    case author
    case state
    case checksSummary
    case headSha
    case mergeable
    case reviewStatus
    case checkStatus
    case policyBlocked
    case isDraft
    case labels
    case checks
    case files
    case activity
    case additions
    case deletions
    case requiredFailedCheckNames
    case viewerCanUpdate
    case viewerCanMergeAsAdmin
    case filePaginationComplete
    case needsYou
    case updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      stationID: try container.decode(String.self, forKey: .stationID),
      repositoryID: try container.decodeIfPresent(String.self, forKey: .repositoryID),
      repository: try container.decode(String.self, forKey: .repository),
      number: try container.decode(Int.self, forKey: .number),
      url: try container.decodeIfPresent(String.self, forKey: .url),
      title: try container.decode(String.self, forKey: .title),
      author: try container.decode(String.self, forKey: .author),
      state: try container.decode(String.self, forKey: .state),
      checksSummary: try container.decode(String.self, forKey: .checksSummary),
      headSha: try container.decodeIfPresent(String.self, forKey: .headSha),
      mergeable: try container.decodeIfPresent(String.self, forKey: .mergeable),
      reviewStatus: try container.decodeIfPresent(String.self, forKey: .reviewStatus),
      checkStatus: try container.decodeIfPresent(String.self, forKey: .checkStatus),
      policyBlocked: try container.decodeIfPresent(Bool.self, forKey: .policyBlocked),
      isDraft: try container.decodeIfPresent(Bool.self, forKey: .isDraft),
      labels: try container.decodeIfPresent([String].self, forKey: .labels) ?? [],
      checks: try container.decodeIfPresent([MobileReviewCheckSnippet].self, forKey: .checks)
        ?? [],
      files: try container.decodeIfPresent([MobileReviewFileSnippet].self, forKey: .files) ?? [],
      activity: try container.decodeIfPresent(
        [MobileReviewActivitySnippet].self,
        forKey: .activity
      ) ?? [],
      additions: try container.decodeIfPresent(UInt64.self, forKey: .additions) ?? 0,
      deletions: try container.decodeIfPresent(UInt64.self, forKey: .deletions) ?? 0,
      requiredFailedCheckNames: try container.decodeIfPresent(
        [String].self,
        forKey: .requiredFailedCheckNames
      ) ?? [],
      viewerCanUpdate: try container.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate) ?? true,
      viewerCanMergeAsAdmin: try container.decodeIfPresent(
        Bool.self,
        forKey: .viewerCanMergeAsAdmin
      ) ?? false,
      filePaginationComplete: try container.decodeIfPresent(
        Bool.self,
        forKey: .filePaginationComplete
      ),
      needsYou: try container.decode(Bool.self, forKey: .needsYou),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt)
    )
  }

  public func commandDraft(
    kind: MobileCommandKind,
    targetRevision: Int64,
    label: String? = nil,
    mergeMethod: String? = nil,
    auditReason: String? = nil,
    expiresAfter: TimeInterval = 15 * 60
  ) -> MobileCommandDraft {
    var payload = commandPayload
    if let label = trimmedPayloadValue(label) {
      payload["label"] = label
    }
    if let mergeMethod = trimmedPayloadValue(mergeMethod) {
      payload["method"] = mergeMethod
    }
    return MobileCommandDraft(
      kind: kind,
      confirmationText: confirmationText(for: kind, label: label, mergeMethod: mergeMethod),
      auditReason: auditReason,
      target: MobileCommandTarget(
        stationID: stationID,
        reviewID: id,
        targetRevision: targetRevision
      ),
      payload: payload,
      expiresAfter: expiresAfter
    )
  }

  public var commandPayload: [String: String] {
    var payload: [String: String] = [
      "pullRequestID": id,
      "repository": repository,
      "number": String(number),
    ]
    payload["repositoryID"] = trimmedPayloadValue(repositoryID)
    payload["url"] = trimmedPayloadValue(url)
    payload["headSha"] = trimmedPayloadValue(headSha)
    payload["mergeable"] = trimmedPayloadValue(mergeable)
    payload["reviewStatus"] = trimmedPayloadValue(reviewStatus)
    payload["checkStatus"] = trimmedPayloadValue(checkStatus)
    payload["state"] = trimmedPayloadValue(state)
    payload["requiredFailedCheckNames"] = csvPayload(requiredFailedCheckNames)
    payload["checkSuiteIDs"] = csvPayload(checks.compactMap(\.checkSuiteID))
    payload["viewerCanUpdate"] = viewerCanUpdate ? "true" : "false"
    payload["viewerCanMergeAsAdmin"] = viewerCanMergeAsAdmin ? "true" : "false"
    if let policyBlocked {
      payload["policyBlocked"] = policyBlocked ? "true" : "false"
    }
    if let isDraft {
      payload["isDraft"] = isDraft ? "true" : "false"
    }
    return payload
  }

  private func csvPayload(_ values: [String]) -> String? {
    let trimmedValues = values.compactMap(trimmedPayloadValue)
    return trimmedValues.isEmpty ? nil : trimmedValues.joined(separator: ",")
  }

  private func confirmationText(
    for kind: MobileCommandKind,
    label: String?,
    mergeMethod: String?
  ) -> String {
    let target = "\(repository) #\(number)"
    switch kind {
    case .pullRequestApprove:
      return "Approve \(target)."
    case .pullRequestLabel:
      let label = trimmedPayloadValue(label) ?? "label"
      return "Apply label \(label) to \(target)."
    case .pullRequestRerunChecks:
      return "Rerun checks for \(target)."
    case .pullRequestMerge:
      let method = trimmedPayloadValue(mergeMethod) ?? "squash"
      return "Merge \(target) with \(method)."
    case .refresh:
      return "Refresh \(target)."
    default:
      return "\(kind.title) for \(target)."
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
      return "Approve plan for \(title)."
    case .taskBoardDispatch:
      if let nextStatus = trimmedPayloadValue(nextStatus) {
        return "Move \(title) to \(nextStatus)."
      }
      return "Dispatch \(title)."
    case .refresh:
      return "Refresh task board item \(title)."
    default:
      return "\(kind.title) for \(title)."
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

public struct MobileMirrorSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var revision: Int64
  public var generatedAt: Date
  public var expiresAt: Date
  public var stations: [MobileStationSummary]
  public var attention: [MobileAttentionItem]
  public var sessions: [MobileSessionSummary]
  public var reviews: [MobileReviewSummary]
  public var taskBoardItems: [MobileTaskBoardSummary]
  public var commands: [MobileCommandRecord]
  public var trustedDevices: [MobileDeviceDescriptor]

  public init(
    schemaVersion: Int = 1,
    revision: Int64,
    generatedAt: Date,
    expiresAt: Date,
    stations: [MobileStationSummary],
    attention: [MobileAttentionItem],
    sessions: [MobileSessionSummary],
    reviews: [MobileReviewSummary],
    taskBoardItems: [MobileTaskBoardSummary] = [],
    commands: [MobileCommandRecord],
    trustedDevices: [MobileDeviceDescriptor] = []
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.generatedAt = generatedAt
    self.expiresAt = expiresAt
    self.stations = stations
    self.attention = attention
    self.sessions = sessions
    self.reviews = reviews
    self.taskBoardItems = taskBoardItems
    self.commands = commands
    self.trustedDevices = trustedDevices
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case revision
    case generatedAt
    case expiresAt
    case stations
    case attention
    case sessions
    case reviews
    case taskBoardItems
    case commands
    case trustedDevices
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
      revision: try container.decode(Int64.self, forKey: .revision),
      generatedAt: try container.decode(Date.self, forKey: .generatedAt),
      expiresAt: try container.decode(Date.self, forKey: .expiresAt),
      stations: try container.decode([MobileStationSummary].self, forKey: .stations),
      attention: try container.decode([MobileAttentionItem].self, forKey: .attention),
      sessions: try container.decode([MobileSessionSummary].self, forKey: .sessions),
      reviews: try container.decode([MobileReviewSummary].self, forKey: .reviews),
      taskBoardItems: try container.decodeIfPresent(
        [MobileTaskBoardSummary].self,
        forKey: .taskBoardItems
      ) ?? [],
      commands: try container.decode([MobileCommandRecord].self, forKey: .commands),
      trustedDevices: try container.decodeIfPresent(
        [MobileDeviceDescriptor].self,
        forKey: .trustedDevices
      ) ?? []
    )
  }

  public var needsYouCount: Int {
    attention.filter(\.needsUserAction).count
  }

  public var sortedAttention: [MobileAttentionItem] {
    attention.sorted {
      if $0.severity.rank != $1.severity.rank {
        return $0.severity.rank < $1.severity.rank
      }
      return $0.updatedAt > $1.updatedAt
    }
  }

  public func taskBoardItems(for stationID: String) -> [MobileTaskBoardSummary] {
    taskBoardItems
      .filter { stationID.isEmpty || $0.stationID == stationID }
      .sorted { lhs, rhs in
        if lhs.needsYou != rhs.needsYou {
          return lhs.needsYou && !rhs.needsYou
        }
        return lhs.updatedAt > rhs.updatedAt
      }
  }

  public func mergingStationSnapshot(
    _ stationSnapshot: MobileMirrorSnapshot,
    stationID: String,
    defaultStationID: String? = nil
  ) -> MobileMirrorSnapshot {
    guard !stationID.isEmpty else {
      return stationSnapshot.normalizingDefaultStation(defaultStationID: defaultStationID)
    }

    var stationIDs = Set(stationSnapshot.stations.map(\.id))
    stationIDs.insert(stationID)

    var merged = self
    merged.schemaVersion = max(schemaVersion, stationSnapshot.schemaVersion)
    merged.revision = max(revision, stationSnapshot.revision)
    merged.generatedAt = max(generatedAt, stationSnapshot.generatedAt)
    merged.expiresAt = max(expiresAt, stationSnapshot.expiresAt)
    merged.stations.removeAll { stationIDs.contains($0.id) }
    merged.attention.removeAll { stationIDs.contains($0.stationID) }
    merged.sessions.removeAll { stationIDs.contains($0.stationID) }
    merged.reviews.removeAll { stationIDs.contains($0.stationID) }
    merged.taskBoardItems.removeAll { stationIDs.contains($0.stationID) }
    merged.commands.removeAll { stationIDs.contains($0.stationID) }
    merged.stations.append(contentsOf: stationSnapshot.stations)
    merged.attention.append(contentsOf: stationSnapshot.attention)
    merged.sessions.append(contentsOf: stationSnapshot.sessions)
    merged.reviews.append(contentsOf: stationSnapshot.reviews)
    merged.taskBoardItems.append(contentsOf: stationSnapshot.taskBoardItems)
    merged.commands.append(contentsOf: stationSnapshot.commands)
    merged.trustedDevices = trustedDevices.mergingTrustedDevices(stationSnapshot.trustedDevices)
    return merged.normalizingDefaultStation(defaultStationID: defaultStationID)
  }

  public func removingStationData(
    for stationIDs: [String],
    defaultStationID: String? = nil
  ) -> MobileMirrorSnapshot {
    let stationIDs = Set(
      stationIDs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    guard !stationIDs.isEmpty else {
      return normalizingDefaultStation(defaultStationID: defaultStationID)
    }

    var pruned = self
    pruned.stations.removeAll { stationIDs.contains($0.id) }
    pruned.attention.removeAll { stationIDs.contains($0.stationID) }
    pruned.sessions.removeAll { stationIDs.contains($0.stationID) }
    pruned.reviews.removeAll { stationIDs.contains($0.stationID) }
    pruned.taskBoardItems.removeAll { stationIDs.contains($0.stationID) }
    pruned.commands.removeAll { stationIDs.contains($0.stationID) }
    return pruned.normalizingDefaultStation(defaultStationID: defaultStationID)
  }

  public static func empty(now: Date = .now) -> Self {
    Self(
      revision: 0,
      generatedAt: now,
      expiresAt: now,
      stations: [],
      attention: [],
      sessions: [],
      reviews: [],
      commands: []
    )
  }

  private func normalizingDefaultStation(
    defaultStationID: String?
  ) -> MobileMirrorSnapshot {
    var normalized = self
    let requestedDefaultStationID = defaultStationID.flatMap { stationID in
      stationID.isEmpty ? nil : stationID
    }
    let resolvedDefaultStationID =
      requestedDefaultStationID
      ?? stations.first(where: \.defaultStation)?.id
      ?? stations.first?.id
    normalized.stations = stations.map { station in
      var station = station
      station.defaultStation = station.id == resolvedDefaultStationID
      return station
    }
    return normalized
  }
}

extension Array where Element == MobileDeviceDescriptor {
  fileprivate func mergingTrustedDevices(_ incoming: [MobileDeviceDescriptor]) -> Self {
    var devicesByID: [String: MobileDeviceDescriptor] = [:]
    var orderedIDs: [String] = []
    for device in self {
      let id = device.collectionID
      if devicesByID[id] == nil {
        orderedIDs.append(id)
      }
      devicesByID[id] = device
    }
    for device in incoming {
      let id = device.collectionID
      if devicesByID[id] == nil {
        orderedIDs.append(id)
      }
      devicesByID[id] = device
    }
    return orderedIDs.compactMap { devicesByID[$0] }
  }
}
