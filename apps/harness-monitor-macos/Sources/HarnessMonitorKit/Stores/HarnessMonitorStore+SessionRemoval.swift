import Foundation

extension HarnessMonitorStore {
  func applyLocalSessionRemoval(
    sessionID: String
  ) -> (projects: [ProjectSummary], sessions: [SessionSummary]) {
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

    if clearsPresentation {
      primeSessionSelection(nil, retainPresentedDetailWhenSelectionClears: false)
      stopSessionStream()
    }

    pruneRemovedSessionNavigation(sessionID: sessionID)

    let updatedSessions = sessions.filter { $0.sessionId != sessionID }
    let updatedProjects = projectSnapshotRemovingRemovedSessions(remainingSessions: updatedSessions)
    withUISyncBatch {
      _ = sessionIndex.replaceSnapshot(projects: updatedProjects, sessions: updatedSessions)
      isShowingCachedCatalog = false
    }
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

  func sessionIndexSnapshotApplyingRemovedSessionSuppression(
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) -> (projects: [ProjectSummary], sessions: [SessionSummary]) {
    guard !locallyRemovedSessionIDs.isEmpty else {
      return (projects, sessions)
    }

    let filteredSessions = sessions.filter { !locallyRemovedSessionIDs.contains($0.sessionId) }
    guard filteredSessions.count != sessions.count else {
      return (projects, filteredSessions)
    }

    return (
      projectSnapshotRemovingRemovedSessions(
        templateProjects: projects,
        remainingSessions: filteredSessions
      ),
      filteredSessions
    )
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

  private func projectSnapshotRemovingRemovedSessions(
    templateProjects: [ProjectSummary]? = nil,
    remainingSessions: [SessionSummary]
  ) -> [ProjectSummary] {
    let sessionsByProject = Dictionary(grouping: remainingSessions, by: \.projectId)
    let activeSessionCount: (SessionSummary) -> Int = { $0.status == .ended ? 0 : 1 }
    let sourceProjects = templateProjects ?? projects

    return sourceProjects.compactMap { project -> ProjectSummary? in
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
