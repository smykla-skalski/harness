import Foundation
import SwiftData

@Model
public final class CachedProject {
  #Unique<CachedProject>([\.projectId])
  #Index<CachedProject>([\.projectId])

  public var projectId: String
  public var name: String
  public var projectDir: String?
  public var contextRoot: String
  public var activeSessionCount: Int
  public var totalSessionCount: Int
  public var lastCachedAt: Date

  public init(
    projectId: String,
    name: String,
    projectDir: String?,
    contextRoot: String,
    activeSessionCount: Int,
    totalSessionCount: Int,
    lastCachedAt: Date = .now
  ) {
    self.projectId = projectId
    self.name = name
    self.projectDir = projectDir
    self.contextRoot = contextRoot
    self.activeSessionCount = activeSessionCount
    self.totalSessionCount = totalSessionCount
    self.lastCachedAt = lastCachedAt
  }
}

@Model
public final class CachedSession {
  #Unique<CachedSession>([\.sessionId])
  #Index<CachedSession>([\.sessionId], [\.projectId], [\.lastViewedAt])

  public var sessionId: String
  public var projectId: String
  public var projectName: String
  public var projectDir: String?
  public var contextRoot: String
  public var context: String
  public var statusRaw: String
  public var createdAt: String
  public var updatedAt: String
  public var lastActivityAt: String?
  public var leaderId: String?
  public var observeId: String?
  public var lastViewedAt: Date?
  public var lastCachedAt: Date
  public var metricsData: Data
  public var pendingTransferData: Data?

  @Relationship(deleteRule: .cascade, inverse: \CachedAgent.session)
  public var agents: [CachedAgent]

  @Relationship(deleteRule: .cascade, inverse: \CachedWorkItem.session)
  public var tasks: [CachedWorkItem]

  @Relationship(deleteRule: .cascade, inverse: \CachedSignalRecord.session)
  public var signals: [CachedSignalRecord]

  @Relationship(deleteRule: .cascade, inverse: \CachedTimelineEntry.session)
  public var timelineEntries: [CachedTimelineEntry]

  @Relationship(deleteRule: .cascade, inverse: \CachedAgentActivity.session)
  public var agentActivity: [CachedAgentActivity]

  @Relationship(deleteRule: .cascade, inverse: \CachedObserver.session)
  public var observer: CachedObserver?

  public init(
    sessionId: String,
    projectId: String,
    projectName: String,
    projectDir: String?,
    contextRoot: String,
    context: String,
    statusRaw: String,
    createdAt: String,
    updatedAt: String,
    lastActivityAt: String?,
    leaderId: String?,
    observeId: String?,
    lastViewedAt: Date? = nil,
    lastCachedAt: Date = .now,
    metricsData: Data,
    pendingTransferData: Data? = nil
  ) {
    self.sessionId = sessionId
    self.projectId = projectId
    self.projectName = projectName
    self.projectDir = projectDir
    self.contextRoot = contextRoot
    self.context = context
    self.statusRaw = statusRaw
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastActivityAt = lastActivityAt
    self.leaderId = leaderId
    self.observeId = observeId
    self.lastViewedAt = lastViewedAt
    self.lastCachedAt = lastCachedAt
    self.metricsData = metricsData
    self.pendingTransferData = pendingTransferData
    self.agents = []
    self.tasks = []
    self.signals = []
    self.timelineEntries = []
    self.agentActivity = []
    self.observer = nil
  }
}

@Model
public final class CachedAgent {
  #Index<CachedAgent>([\.agentId])

  public var agentId: String
  public var name: String
  public var runtime: String
  public var roleRaw: String
  public var statusRaw: String
  public var joinedAt: String
  public var updatedAt: String
  public var agentSessionId: String?
  public var lastActivityAt: String?
  public var currentTaskId: String?
  public var capabilitiesData: Data
  public var runtimeCapabilitiesData: Data

  public var session: CachedSession?

  public init(
    agentId: String,
    name: String,
    runtime: String,
    roleRaw: String,
    statusRaw: String,
    joinedAt: String,
    updatedAt: String,
    agentSessionId: String?,
    lastActivityAt: String?,
    currentTaskId: String?,
    capabilitiesData: Data,
    runtimeCapabilitiesData: Data
  ) {
    self.agentId = agentId
    self.name = name
    self.runtime = runtime
    self.roleRaw = roleRaw
    self.statusRaw = statusRaw
    self.joinedAt = joinedAt
    self.updatedAt = updatedAt
    self.agentSessionId = agentSessionId
    self.lastActivityAt = lastActivityAt
    self.currentTaskId = currentTaskId
    self.capabilitiesData = capabilitiesData
    self.runtimeCapabilitiesData = runtimeCapabilitiesData
  }
}

@Model
public final class CachedWorkItem {
  #Index<CachedWorkItem>([\.taskId])

  public var taskId: String
  public var title: String
  public var context: String?
  public var severityRaw: String
  public var statusRaw: String
  public var assignedTo: String?
  public var createdAt: String
  public var updatedAt: String
  public var createdBy: String?
  public var suggestedFix: String?
  public var sourceRaw: String
  public var blockedReason: String?
  public var completedAt: String?
  public var notesData: Data
  public var checkpointData: Data?

  public var session: CachedSession?

  public init(
    taskId: String,
    title: String,
    context: String?,
    severityRaw: String,
    statusRaw: String,
    assignedTo: String?,
    createdAt: String,
    updatedAt: String,
    createdBy: String?,
    suggestedFix: String?,
    sourceRaw: String,
    blockedReason: String?,
    completedAt: String?,
    notesData: Data,
    checkpointData: Data?
  ) {
    self.taskId = taskId
    self.title = title
    self.context = context
    self.severityRaw = severityRaw
    self.statusRaw = statusRaw
    self.assignedTo = assignedTo
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.createdBy = createdBy
    self.suggestedFix = suggestedFix
    self.sourceRaw = sourceRaw
    self.blockedReason = blockedReason
    self.completedAt = completedAt
    self.notesData = notesData
    self.checkpointData = checkpointData
  }
}

@Model
public final class CachedSignalRecord {
  #Index<CachedSignalRecord>([\.signalId])

  public var signalId: String
  public var runtime: String
  public var agentId: String
  public var sessionId: String
  public var statusRaw: String
  public var signalData: Data
  public var acknowledgmentData: Data?

  public var session: CachedSession?

  public init(
    signalId: String,
    runtime: String,
    agentId: String,
    sessionId: String,
    statusRaw: String,
    signalData: Data,
    acknowledgmentData: Data?
  ) {
    self.signalId = signalId
    self.runtime = runtime
    self.agentId = agentId
    self.sessionId = sessionId
    self.statusRaw = statusRaw
    self.signalData = signalData
    self.acknowledgmentData = acknowledgmentData
  }
}

@Model
public final class CachedTimelineEntry {
  #Index<CachedTimelineEntry>([\.entryId])

  public var entryId: String
  public var recordedAt: String
  public var kind: String
  public var sessionId: String
  public var agentId: String?
  public var taskId: String?
  public var summary: String
  public var payloadData: Data

  public var session: CachedSession?

  public init(
    entryId: String,
    recordedAt: String,
    kind: String,
    sessionId: String,
    agentId: String?,
    taskId: String?,
    summary: String,
    payloadData: Data
  ) {
    self.entryId = entryId
    self.recordedAt = recordedAt
    self.kind = kind
    self.sessionId = sessionId
    self.agentId = agentId
    self.taskId = taskId
    self.summary = summary
    self.payloadData = payloadData
  }
}

@Model
public final class CachedObserver {
  public var observeId: String
  public var lastScanTime: String
  public var openIssueCount: Int
  public var resolvedIssueCount: Int
  public var mutedCodeCount: Int
  public var activeWorkerCount: Int
  public var detailData: Data

  public var session: CachedSession?

  public init(
    observeId: String,
    lastScanTime: String,
    openIssueCount: Int,
    resolvedIssueCount: Int,
    mutedCodeCount: Int,
    activeWorkerCount: Int,
    detailData: Data
  ) {
    self.observeId = observeId
    self.lastScanTime = lastScanTime
    self.openIssueCount = openIssueCount
    self.resolvedIssueCount = resolvedIssueCount
    self.mutedCodeCount = mutedCodeCount
    self.activeWorkerCount = activeWorkerCount
    self.detailData = detailData
  }
}

@Model
public final class CachedAgentActivity {
  public var agentId: String
  public var runtime: String
  public var toolInvocationCount: Int
  public var toolResultCount: Int
  public var toolErrorCount: Int
  public var latestToolName: String?
  public var latestEventAt: String?
  public var recentToolsData: Data

  public var session: CachedSession?

  public init(
    agentId: String,
    runtime: String,
    toolInvocationCount: Int,
    toolResultCount: Int,
    toolErrorCount: Int,
    latestToolName: String?,
    latestEventAt: String?,
    recentToolsData: Data
  ) {
    self.agentId = agentId
    self.runtime = runtime
    self.toolInvocationCount = toolInvocationCount
    self.toolResultCount = toolResultCount
    self.toolErrorCount = toolErrorCount
    self.latestToolName = latestToolName
    self.latestEventAt = latestEventAt
    self.recentToolsData = recentToolsData
  }
}
