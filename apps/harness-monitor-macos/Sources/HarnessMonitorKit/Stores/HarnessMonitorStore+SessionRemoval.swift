import Foundation

extension HarnessMonitorStore {
  func applyLocalSessionRemoval(
    sessionID: String
  ) -> (projects: [ProjectSummary], sessions: [SessionSummary]) {
    locallyRemovedSessionIDs.insert(sessionID)
    cancelPendingListSelection()
    cancelSessionPushFallback(for: sessionID)
    cancelSelectedSessionRefreshFallback(for: sessionID)

    if selectedSessionID == sessionID {
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

    return (self.projects, filteredSessions)
  }

  func shouldIgnoreLocallyRemovedSession(_ sessionID: String) -> Bool {
    locallyRemovedSessionIDs.contains(sessionID)
  }

  private func projectSnapshotRemovingRemovedSessions(
    remainingSessions: [SessionSummary]
  ) -> [ProjectSummary] {
    let sessionsByProject = Dictionary(grouping: remainingSessions, by: \.projectId)
    let activeSessionCount: (SessionSummary) -> Int = { $0.status == .ended ? 0 : 1 }

    return projects.compactMap { project -> ProjectSummary? in
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
