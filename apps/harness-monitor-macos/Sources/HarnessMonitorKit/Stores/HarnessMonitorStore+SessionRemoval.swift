import Foundation

struct SessionSnapshotWorkerInput: Sendable {
  let projects: [ProjectSummary]
  let sessions: [SessionSummary]
  let locallyRemovedSessionIDs: Set<String>
  let selectedSessionID: String?
  let presentedDetailSessionID: String?
}

struct SessionSnapshotWorkerOutput: Sendable {
  let projects: [ProjectSummary]
  let sessions: [SessionSummary]
  let sessionSummariesByID: [String: SessionSummary]
  let sessionIndicesByID: [String: Int]
  let selectedSessionSummary: SessionSummary?
  let selectionMissingFromSnapshot: Bool
  let presentedDetailMissingFromSnapshot: Bool
  let projectCount: Int
  let worktreeCount: Int
  let sessionCount: Int
  let openWorkCount: Int
  let blockedCount: Int
}

extension HarnessMonitorStore {
  func applyLocalSessionRemoval(
    sessionID: String
  ) async -> (projects: [ProjectSummary], sessions: [SessionSummary]) {
    let clearsPresentation = shouldClearRemovedSessionPresentation(sessionID: sessionID)
    HarnessMonitorUITestTrace.record(
      component: "store.session-removal",
      event: "local-removal-begin",
      details: [
        "session_id": sessionID,
        "selected_session_id": selectedSessionID ?? "nil",
        "selected_summary_id": selectedSessionSummary?.sessionId ?? "nil",
        "presented_detail_id": contentUI.sessionDetail.presentedSessionDetail?.session.sessionId
          ?? "nil",
        "clears_presentation": String(clearsPresentation),
      ]
    )
    locallyRemovedSessionIDs.insert(sessionID)
    cancelPendingListSelection()
    cancelSessionPushFallback(for: sessionID)
    cancelSelectedSessionRefreshFallback(for: sessionID)
    if pendingSessionRouteCreateSessionID == sessionID {
      pendingSessionRouteCreateSessionID = nil
    }

    if clearsPresentation {
      primeSessionSelection(nil, retainPresentedDetailWhenSelectionClears: false)
      stopSessionStream()
    }

    pruneRemovedSessionNavigation(sessionID: sessionID)

    let generation = beginSessionIndexSnapshotApply()
    let preparedSnapshot = await sessionSnapshotWorker.prepare(
      input: sessionSnapshotWorkerInput(projects: projects, sessions: sessions)
    )
    if isCurrentSessionIndexSnapshotApply(generation) {
      applyPreparedSessionIndexSnapshot(preparedSnapshot)
    }
    let updatedProjects = preparedSnapshot.projects
    let updatedSessions = preparedSnapshot.sessions
    HarnessMonitorUITestTrace.record(
      component: "store.session-removal",
      event: "local-removal-end",
      details: [
        "session_id": sessionID,
        "remaining_session_count": String(updatedSessions.count),
        "remaining_project_count": String(updatedProjects.count),
        "selected_session_id": selectedSessionID ?? "nil",
      ]
    )
    return (updatedProjects, updatedSessions)
  }

  private func pruneRemovedSessionNavigation(sessionID: String) {
    navigationBackStack.removeAll { $0 == sessionID }
    navigationForwardStack.removeAll { $0 == sessionID }
  }

  func shouldIgnoreLocallyRemovedSession(_ sessionID: String) -> Bool {
    locallyRemovedSessionIDs.contains(sessionID)
  }

  private func shouldClearRemovedSessionPresentation(sessionID: String) -> Bool {
    if selectedSessionID == sessionID {
      return true
    }
    if selectedSessionSummary?.sessionId == sessionID {
      return true
    }
    if contentUI.session.selectedSessionSummary?.sessionId == sessionID {
      return true
    }
    if selectedSession?.session.sessionId == sessionID {
      return true
    }
    if contentUI.sessionDetail.presentedSessionDetail?.session.sessionId == sessionID {
      return true
    }
    return false
  }

  func beginSessionIndexSnapshotApply() -> UInt64 {
    sessionIndexSnapshotApplyTask?.cancel()
    sessionIndexSnapshotApplyTask = nil
    sessionIndexSnapshotApplyGeneration &+= 1
    return sessionIndexSnapshotApplyGeneration
  }

  func isCurrentSessionIndexSnapshotApply(_ generation: UInt64) -> Bool {
    generation == sessionIndexSnapshotApplyGeneration
  }

  func sessionSnapshotWorkerInput(
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) -> SessionSnapshotWorkerInput {
    SessionSnapshotWorkerInput(
      projects: projects,
      sessions: sessions,
      locallyRemovedSessionIDs: locallyRemovedSessionIDs,
      selectedSessionID: selectedSessionID,
      presentedDetailSessionID: contentUI.sessionDetail.presentedSessionDetail?.session.sessionId
    )
  }

  func preparedSessionIndexSnapshot(
    projects: [ProjectSummary],
    sessions: [SessionSummary],
    generation: UInt64
  ) async -> SessionSnapshotWorkerOutput? {
    let input = sessionSnapshotWorkerInput(projects: projects, sessions: sessions)
    let output = await sessionSnapshotWorker.prepare(input: input)
    guard !Task.isCancelled, isCurrentSessionIndexSnapshotApply(generation) else {
      return nil
    }
    return output
  }

  func applyPreparedSessionIndexSnapshot(
    _ preparedSnapshot: SessionSnapshotWorkerOutput
  ) {
    if preparedSnapshot.selectionMissingFromSnapshot
      || preparedSnapshot.presentedDetailMissingFromSnapshot
    {
      primeSessionSelection(nil, retainPresentedDetailWhenSelectionClears: false)
      stopSessionStream()
    }

    var didChange = false
    withUISyncBatch {
      didChange = sessionIndex.replaceSnapshot(
        projects: preparedSnapshot.projects,
        sessions: preparedSnapshot.sessions
      )
      applyPreparedSessionLookupState(preparedSnapshot)
      applySidebarSnapshotCounts(preparedSnapshot)
      isShowingCachedCatalog = false
    }
    if didChange {
      let sessions = preparedSnapshot.sessions
      let projects = preparedSnapshot.projects
      scheduleCacheWrite { service in
        await service.cacheSessionList(sessions, projects: projects)
      }
    }
    #if HARNESS_FEATURE_OTEL
      recordActiveTaskGauge()
    #endif

    if let selectedSessionID, sessionIndex.sessionSummary(for: selectedSessionID) == nil {
      primeSessionSelection(nil, retainPresentedDetailWhenSelectionClears: false)
      stopSessionStream()
    }
  }

  func replaceCachedSessionIndexSnapshot(
    _ preparedSnapshot: SessionSnapshotWorkerOutput,
    updateCachedCatalogFlag: Bool
  ) {
    withUISyncBatch {
      sessionIndex.replaceSnapshot(
        projects: preparedSnapshot.projects,
        sessions: preparedSnapshot.sessions
      )
      applyPreparedSessionLookupState(preparedSnapshot)
      applySidebarSnapshotCounts(preparedSnapshot)
      if updateCachedCatalogFlag {
        isShowingCachedCatalog = persistedSessionCount > 0 || !preparedSnapshot.sessions.isEmpty
      }
    }
  }

  func scheduleSessionIndexSnapshotApply(
    projects: [ProjectSummary],
    sessions: [SessionSummary],
    refreshSelectedSession: Bool
  ) {
    let generation = beginSessionIndexSnapshotApply()
    let input = sessionSnapshotWorkerInput(projects: projects, sessions: sessions)
    sessionIndexSnapshotApplyTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      let preparedSnapshot = await self.sessionSnapshotWorker.prepare(input: input)
      guard !Task.isCancelled, self.isCurrentSessionIndexSnapshotApply(generation) else {
        return
      }
      self.applyPreparedSessionIndexSnapshot(preparedSnapshot)
      if refreshSelectedSession {
        self.refreshSelectedSessionIfSummaryChanged(
          updatedSummary: preparedSnapshot.selectedSessionSummary
        )
      }
      self.sessionIndexSnapshotApplyTask = nil
    }
  }

  nonisolated static func prepareSessionSnapshot(
    from input: SessionSnapshotWorkerInput
  ) -> SessionSnapshotWorkerOutput {
    let filteredSessions: [SessionSummary]
    let filteredProjects: [ProjectSummary]
    if input.locallyRemovedSessionIDs.isEmpty {
      filteredSessions = input.sessions
      filteredProjects = input.projects
    } else {
      filteredSessions = input.sessions.filter {
        !input.locallyRemovedSessionIDs.contains($0.sessionId)
      }
      if filteredSessions.count == input.sessions.count {
        filteredProjects = input.projects
      } else {
        filteredProjects = projectSnapshotRemovingRemovedSessions(
          templateProjects: input.projects,
          remainingSessions: filteredSessions
        )
      }
    }

    var summariesByID: [String: SessionSummary] = [:]
    var indicesByID: [String: Int] = [:]
    summariesByID.reserveCapacity(filteredSessions.count)
    indicesByID.reserveCapacity(filteredSessions.count)
    for (index, summary) in filteredSessions.enumerated() {
      summariesByID[summary.sessionId] = summary
      indicesByID[summary.sessionId] = index
    }
    let selectedSessionSummary = input.selectedSessionID.flatMap { summariesByID[$0] }
    let selectionMissingFromSnapshot =
      input.selectedSessionID.map { summariesByID[$0] == nil } ?? false
    let presentedDetailMissingFromSnapshot =
      input.presentedDetailSessionID.map { summariesByID[$0] == nil } ?? false
    let sessionBackedProjectCount = Set(filteredSessions.map(\.projectId)).count
    let sessionBackedWorktreeCount = Set(
      filteredSessions.compactMap { $0.isWorktree ? $0.checkoutId : nil }
    ).count
    return SessionSnapshotWorkerOutput(
      projects: filteredProjects,
      sessions: filteredSessions,
      sessionSummariesByID: summariesByID,
      sessionIndicesByID: indicesByID,
      selectedSessionSummary: selectedSessionSummary,
      selectionMissingFromSnapshot: selectionMissingFromSnapshot,
      presentedDetailMissingFromSnapshot: presentedDetailMissingFromSnapshot,
      projectCount: sessionBackedProjectCount,
      worktreeCount: sessionBackedWorktreeCount,
      sessionCount: filteredSessions.count,
      openWorkCount: filteredSessions.reduce(0) { $0 + $1.metrics.openTaskCount },
      blockedCount: filteredSessions.reduce(0) { $0 + $1.metrics.blockedTaskCount }
    )
  }

  private func applyPreparedSessionLookupState(_ preparedSnapshot: SessionSnapshotWorkerOutput) {
    sessionIndex.catalog.sessionSummariesByID = preparedSnapshot.sessionSummariesByID
    sessionIndex.catalog.totalSessionCount = preparedSnapshot.sessionCount
    sessionIndex.catalog.totalOpenWorkCount = preparedSnapshot.openWorkCount
    sessionIndex.catalog.totalBlockedCount = preparedSnapshot.blockedCount
    sessionIndex.sessionIndicesByID = preparedSnapshot.sessionIndicesByID
  }

  private func applySidebarSnapshotCounts(_ preparedSnapshot: SessionSnapshotWorkerOutput) {
    sidebarUI.apply(
      SidebarUIState(
        selectedSessionID: selection.selectedSessionID,
        isPersistenceAvailable: isPersistenceAvailable,
        bookmarkedSessionIds: userData.bookmarkedSessionIds,
        projectCount: preparedSnapshot.projectCount,
        worktreeCount: preparedSnapshot.worktreeCount,
        sessionCount: preparedSnapshot.sessionCount,
        openWorkCount: preparedSnapshot.openWorkCount,
        blockedCount: preparedSnapshot.blockedCount
      )
    )
  }

  nonisolated static func projectSnapshotRemovingRemovedSessions(
    templateProjects: [ProjectSummary],
    remainingSessions: [SessionSummary]
  ) -> [ProjectSummary] {
    let sessionsByProject = Dictionary(grouping: remainingSessions, by: \.projectId)
    let activeSessionCount: (SessionSummary) -> Int = { $0.status == .ended ? 0 : 1 }

    return templateProjects.compactMap { project -> ProjectSummary? in
      let projectSessions = sessionsByProject[project.projectId] ?? []
      guard !projectSessions.isEmpty else {
        return nil
      }

      let sessionsByCheckout = Dictionary(grouping: projectSessions, by: \.checkoutId)
      let worktrees = project.worktrees.compactMap { worktree -> WorktreeSummary? in
        let checkoutSessions = sessionsByCheckout[worktree.checkoutId] ?? []
        guard !checkoutSessions.isEmpty else {
          return nil
        }

        return WorktreeSummary(
          checkoutId: worktree.checkoutId,
          name: worktree.name,
          checkoutRoot: worktree.checkoutRoot,
          contextRoot: worktree.contextRoot,
          activeSessionCount: checkoutSessions.reduce(into: 0) { partialResult, session in
            partialResult += activeSessionCount(session)
          },
          totalSessionCount: checkoutSessions.count
        )
      }

      return ProjectSummary(
        projectId: project.projectId,
        name: project.name,
        projectDir: project.projectDir,
        contextRoot: project.contextRoot,
        activeSessionCount: projectSessions.reduce(into: 0) { partialResult, session in
          partialResult += activeSessionCount(session)
        },
        totalSessionCount: projectSessions.count,
        worktrees: worktrees
      )
    }
  }
}

actor SessionSnapshotWorker {
  func prepare(input: SessionSnapshotWorkerInput) -> SessionSnapshotWorkerOutput {
    HarnessMonitorStore.prepareSessionSnapshot(from: input)
  }

  func waitForIdle() async {}
}
