import Foundation
import SwiftData

extension HarnessMonitorSchemaV5 {
  @Model
  final class CachedProject {
    #Unique<CachedProject>([\.projectId])
    #Index<CachedProject>([\.projectId])

    var projectId: String
    var name: String
    var projectDir: String?
    var contextRoot: String
    var activeSessionCount: Int
    var totalSessionCount: Int
    var worktreesData = Data()
    var lastCachedAt: Date

    init(
      projectId: String,
      name: String,
      projectDir: String?,
      contextRoot: String,
      activeSessionCount: Int,
      totalSessionCount: Int,
      worktreesData: Data = Data(),
      lastCachedAt: Date = .now
    ) {
      self.projectId = projectId
      self.name = name
      self.projectDir = projectDir
      self.contextRoot = contextRoot
      self.activeSessionCount = activeSessionCount
      self.totalSessionCount = totalSessionCount
      self.worktreesData = worktreesData
      self.lastCachedAt = lastCachedAt
    }
  }

  @Model
  final class CachedSession {
    #Unique<CachedSession>([\.sessionId])
    #Index<CachedSession>([\.sessionId], [\.projectId], [\.lastViewedAt])

    var sessionId: String
    var projectId: String
    var projectName: String
    var projectDir: String?
    var contextRoot: String
    var checkoutId: String = ""
    var checkoutRoot: String = ""
    var isWorktree: Bool = false
    var worktreeName: String?
    var title: String = ""
    var context: String
    var statusRaw: String
    var createdAt: String
    var updatedAt: String
    var lastActivityAt: String?
    var leaderId: String?
    var observeId: String?
    var lastViewedAt: Date?
    var lastCachedAt: Date
    var metricsData: Data
    var pendingTransferData: Data?
    var timelineWindowData: Data?

    @Relationship(deleteRule: .cascade, inverse: \CachedAgent.session)
    var agents: [CachedAgent]

    @Relationship(deleteRule: .cascade, inverse: \CachedWorkItem.session)
    var tasks: [CachedWorkItem]

    @Relationship(deleteRule: .cascade, inverse: \CachedSignalRecord.session)
    var signals: [CachedSignalRecord]

    @Relationship(deleteRule: .cascade, inverse: \CachedTimelineEntry.session)
    var timelineEntries: [CachedTimelineEntry]

    @Relationship(deleteRule: .cascade, inverse: \CachedAgentActivity.session)
    var agentActivity: [CachedAgentActivity]

    @Relationship(deleteRule: .cascade, inverse: \CachedObserver.session)
    var observer: CachedObserver?

    init(
      sessionId: String,
      projectId: String,
      projectName: String,
      projectDir: String?,
      contextRoot: String,
      checkoutId: String,
      checkoutRoot: String,
      isWorktree: Bool,
      worktreeName: String?,
      title: String = "",
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
      pendingTransferData: Data? = nil,
      timelineWindowData: Data? = nil
    ) {
      self.sessionId = sessionId
      self.projectId = projectId
      self.projectName = projectName
      self.projectDir = projectDir
      self.contextRoot = contextRoot
      self.checkoutId = checkoutId
      self.checkoutRoot = checkoutRoot
      self.isWorktree = isWorktree
      self.worktreeName = worktreeName
      self.title = title
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
      self.timelineWindowData = timelineWindowData
      self.agents = []
      self.tasks = []
      self.signals = []
      self.timelineEntries = []
      self.agentActivity = []
      self.observer = nil
    }
  }

  @Model
  final class CachedAgent {
    #Index<CachedAgent>([\.agentId])

    var agentId: String
    var name: String
    var runtime: String
    var roleRaw: String
    var statusRaw: String
    var joinedAt: String
    var updatedAt: String
    var agentSessionId: String?
    var lastActivityAt: String?
    var currentTaskId: String?
    var capabilitiesData: Data
    var runtimeCapabilitiesData: Data

    var session: CachedSession?

    init(
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
  final class CachedWorkItem {
    #Index<CachedWorkItem>([\.taskId])

    var taskId: String
    var title: String
    var context: String?
    var severityRaw: String
    var statusRaw: String
    var assignedTo: String?
    var queuePolicyRaw: String = TaskQueuePolicy.locked.rawValue
    var queuedAt: String?
    var createdAt: String
    var updatedAt: String
    var createdBy: String?
    var suggestedFix: String?
    var sourceRaw: String
    var blockedReason: String?
    var completedAt: String?
    var notesData: Data
    var checkpointData: Data?

    var session: CachedSession?

    init(
      taskId: String,
      title: String,
      context: String?,
      severityRaw: String,
      statusRaw: String,
      assignedTo: String?,
      queuePolicyRaw: String = TaskQueuePolicy.locked.rawValue,
      queuedAt: String? = nil,
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
      self.queuePolicyRaw = queuePolicyRaw
      self.queuedAt = queuedAt
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
  final class CachedSignalRecord {
    #Index<CachedSignalRecord>([\.signalId])

    var signalId: String
    var runtime: String
    var agentId: String
    var sessionId: String
    var statusRaw: String
    var signalData: Data
    var acknowledgmentData: Data?

    var session: CachedSession?

    init(
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
  final class CachedTimelineEntry {
    #Index<CachedTimelineEntry>([\.entryId])

    var entryId: String
    var recordedAt: String
    var kind: String
    var sessionId: String
    var agentId: String?
    var taskId: String?
    var summary: String
    var payloadData: Data

    var session: CachedSession?

    init(
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
  final class CachedObserver {
    var observeId: String
    var lastScanTime: String
    var openIssueCount: Int
    var resolvedIssueCount: Int
    var mutedCodeCount: Int
    var activeWorkerCount: Int
    var detailData: Data

    var session: CachedSession?

    init(
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
  final class CachedAgentActivity {
    var agentId: String
    var runtime: String
    var toolInvocationCount: Int
    var toolResultCount: Int
    var toolErrorCount: Int
    var latestToolName: String?
    var latestEventAt: String?
    var recentToolsData: Data

    var session: CachedSession?

    init(
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
}

typealias CachedProject = HarnessMonitorCurrentSchema.CachedProject
typealias CachedSession = HarnessMonitorCurrentSchema.CachedSession
typealias CachedAgent = HarnessMonitorCurrentSchema.CachedAgent
typealias CachedWorkItem = HarnessMonitorCurrentSchema.CachedWorkItem
typealias CachedSignalRecord = HarnessMonitorCurrentSchema.CachedSignalRecord
typealias CachedTimelineEntry = HarnessMonitorCurrentSchema.CachedTimelineEntry
typealias CachedObserver = HarnessMonitorCurrentSchema.CachedObserver
typealias CachedAgentActivity = HarnessMonitorCurrentSchema.CachedAgentActivity
