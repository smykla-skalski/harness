import Foundation
import SwiftData

// MARK: - ProjectSummary <-> CachedProject

extension CachedProject {
  public func toProjectSummary() -> ProjectSummary {
    ProjectSummary(
      projectId: projectId,
      name: name,
      projectDir: projectDir,
      contextRoot: contextRoot,
      activeSessionCount: activeSessionCount,
      totalSessionCount: totalSessionCount
    )
  }

  public func update(from summary: ProjectSummary) {
    name = summary.name
    projectDir = summary.projectDir
    contextRoot = summary.contextRoot
    activeSessionCount = summary.activeSessionCount
    totalSessionCount = summary.totalSessionCount
    lastCachedAt = .now
  }
}

extension ProjectSummary {
  public func toCachedProject() -> CachedProject {
    CachedProject(
      projectId: projectId,
      name: name,
      projectDir: projectDir,
      contextRoot: contextRoot,
      activeSessionCount: activeSessionCount,
      totalSessionCount: totalSessionCount
    )
  }
}

// MARK: - SessionSummary <-> CachedSession

extension CachedSession {
  public func toSessionSummary() -> SessionSummary {
    let metrics = (try? JSONDecoder().decode(SessionMetrics.self, from: metricsData))
      ?? SessionMetrics(
        agentCount: 0,
        activeAgentCount: 0,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )

    let transfer: PendingLeaderTransfer? =
      if let data = pendingTransferData {
        try? JSONDecoder().decode(PendingLeaderTransfer.self, from: data)
      } else {
        nil
      }

    return SessionSummary(
      projectId: projectId,
      projectName: projectName,
      projectDir: projectDir,
      contextRoot: contextRoot,
      sessionId: sessionId,
      context: context,
      status: SessionStatus(rawValue: statusRaw) ?? .active,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastActivityAt: lastActivityAt,
      leaderId: leaderId,
      observeId: observeId,
      pendingLeaderTransfer: transfer,
      metrics: metrics
    )
  }

  public func toSessionDetail() -> SessionDetail {
    SessionDetail(
      session: toSessionSummary(),
      agents: agents.map { $0.toAgentRegistration() },
      tasks: tasks.map { $0.toWorkItem() },
      signals: signals.map { $0.toSessionSignalRecord() },
      observer: observer?.toObserverSummary(),
      agentActivity: agentActivity.map { $0.toAgentToolActivitySummary() }
    )
  }

  public func update(from summary: SessionSummary) {
    projectId = summary.projectId
    projectName = summary.projectName
    projectDir = summary.projectDir
    contextRoot = summary.contextRoot
    context = summary.context
    statusRaw = summary.status.rawValue
    createdAt = summary.createdAt
    updatedAt = summary.updatedAt
    lastActivityAt = summary.lastActivityAt
    leaderId = summary.leaderId
    observeId = summary.observeId
    metricsData = (try? JSONEncoder().encode(summary.metrics)) ?? Data()
    pendingTransferData = summary.pendingLeaderTransfer.flatMap { try? JSONEncoder().encode($0) }
    lastCachedAt = .now
  }
}

extension SessionSummary {
  public func toCachedSession() -> CachedSession {
    CachedSession(
      sessionId: sessionId,
      projectId: projectId,
      projectName: projectName,
      projectDir: projectDir,
      contextRoot: contextRoot,
      context: context,
      statusRaw: status.rawValue,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastActivityAt: lastActivityAt,
      leaderId: leaderId,
      observeId: observeId,
      metricsData: (try? JSONEncoder().encode(metrics)) ?? Data(),
      pendingTransferData: pendingLeaderTransfer.flatMap { try? JSONEncoder().encode($0) }
    )
  }
}

// MARK: - AgentRegistration <-> CachedAgent

extension CachedAgent {
  public func toAgentRegistration() -> AgentRegistration {
    let capabilities = (try? JSONDecoder().decode([String].self, from: capabilitiesData)) ?? []
    let runtimeCapabilities =
      (try? JSONDecoder().decode(RuntimeCapabilities.self, from: runtimeCapabilitiesData))
      ?? RuntimeCapabilities(
        runtime: runtime,
        supportsNativeTranscript: false,
        supportsSignalDelivery: false,
        supportsContextInjection: false,
        typicalSignalLatencySeconds: 0,
        hookPoints: []
      )

    return AgentRegistration(
      agentId: agentId,
      name: name,
      runtime: runtime,
      role: SessionRole(rawValue: roleRaw) ?? .worker,
      capabilities: capabilities,
      joinedAt: joinedAt,
      updatedAt: updatedAt,
      status: AgentStatus(rawValue: statusRaw) ?? .active,
      agentSessionId: agentSessionId,
      lastActivityAt: lastActivityAt,
      currentTaskId: currentTaskId,
      runtimeCapabilities: runtimeCapabilities
    )
  }

  public func update(from registration: AgentRegistration) {
    name = registration.name
    runtime = registration.runtime
    roleRaw = registration.role.rawValue
    statusRaw = registration.status.rawValue
    joinedAt = registration.joinedAt
    updatedAt = registration.updatedAt
    agentSessionId = registration.agentSessionId
    lastActivityAt = registration.lastActivityAt
    currentTaskId = registration.currentTaskId
    capabilitiesData = (try? JSONEncoder().encode(registration.capabilities)) ?? Data()
    runtimeCapabilitiesData =
      (try? JSONEncoder().encode(registration.runtimeCapabilities)) ?? Data()
  }
}

extension AgentRegistration {
  public func toCachedAgent() -> CachedAgent {
    CachedAgent(
      agentId: agentId,
      name: name,
      runtime: runtime,
      roleRaw: role.rawValue,
      statusRaw: status.rawValue,
      joinedAt: joinedAt,
      updatedAt: updatedAt,
      agentSessionId: agentSessionId,
      lastActivityAt: lastActivityAt,
      currentTaskId: currentTaskId,
      capabilitiesData: (try? JSONEncoder().encode(capabilities)) ?? Data(),
      runtimeCapabilitiesData: (try? JSONEncoder().encode(runtimeCapabilities)) ?? Data()
    )
  }
}

// MARK: - WorkItem <-> CachedWorkItem

extension CachedWorkItem {
  public func toWorkItem() -> WorkItem {
    let notes = (try? JSONDecoder().decode([TaskNote].self, from: notesData)) ?? []
    let checkpoint: TaskCheckpointSummary? =
      if let data = checkpointData {
        try? JSONDecoder().decode(TaskCheckpointSummary.self, from: data)
      } else {
        nil
      }

    return WorkItem(
      taskId: taskId,
      title: title,
      context: context,
      severity: TaskSeverity(rawValue: severityRaw) ?? .medium,
      status: TaskStatus(rawValue: statusRaw) ?? .open,
      assignedTo: assignedTo,
      createdAt: createdAt,
      updatedAt: updatedAt,
      createdBy: createdBy,
      notes: notes,
      suggestedFix: suggestedFix,
      source: TaskSource(rawValue: sourceRaw) ?? .manual,
      blockedReason: blockedReason,
      completedAt: completedAt,
      checkpointSummary: checkpoint
    )
  }

  public func update(from item: WorkItem) {
    title = item.title
    context = item.context
    severityRaw = item.severity.rawValue
    statusRaw = item.status.rawValue
    assignedTo = item.assignedTo
    createdAt = item.createdAt
    updatedAt = item.updatedAt
    createdBy = item.createdBy
    suggestedFix = item.suggestedFix
    sourceRaw = item.source.rawValue
    blockedReason = item.blockedReason
    completedAt = item.completedAt
    notesData = (try? JSONEncoder().encode(item.notes)) ?? Data()
    checkpointData = item.checkpointSummary.flatMap { try? JSONEncoder().encode($0) }
  }
}

extension WorkItem {
  public func toCachedWorkItem() -> CachedWorkItem {
    CachedWorkItem(
      taskId: taskId,
      title: title,
      context: context,
      severityRaw: severity.rawValue,
      statusRaw: status.rawValue,
      assignedTo: assignedTo,
      createdAt: createdAt,
      updatedAt: updatedAt,
      createdBy: createdBy,
      suggestedFix: suggestedFix,
      sourceRaw: source.rawValue,
      blockedReason: blockedReason,
      completedAt: completedAt,
      notesData: (try? JSONEncoder().encode(notes)) ?? Data(),
      checkpointData: checkpointSummary.flatMap { try? JSONEncoder().encode($0) }
    )
  }
}
