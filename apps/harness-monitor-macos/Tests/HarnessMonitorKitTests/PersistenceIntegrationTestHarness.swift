import Foundation
import SwiftData

@testable import HarnessMonitorKit

struct PersistenceLargeSnapshotFixture {
  let projects: [ProjectSummary]
  let sessions: [SessionSummary]
  let detailsByID: [String: SessionDetail]
}

@MainActor
struct PersistenceIntegrationTestHarness {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
  }

  func fetchNotes(
    targetId: String,
    sessionId: String
  ) throws -> [UserNote] {
    let notes = try container.mainContext.fetch(FetchDescriptor<UserNote>())
    return
      notes
      .filter { $0.targetId == targetId && $0.sessionId == sessionId }
      .sorted { $0.createdAt > $1.createdAt }
  }

  func fetchRecentSearches() throws -> [RecentSearch] {
    try container.mainContext.fetch(
      FetchDescriptor<RecentSearch>(
        sortBy: [SortDescriptor(\RecentSearch.lastUsedAt, order: .reverse)]
      ))
  }

  func largeSnapshotFixture(
    projectCount: Int = 6,
    sessionsPerProject: Int = 12
  ) -> PersistenceLargeSnapshotFixture {
    var projects: [ProjectSummary] = []
    var sessions: [SessionSummary] = []
    var detailsByID: [String: SessionDetail] = [:]

    for projectIndex in 0..<projectCount {
      let projectId = "project-\(projectIndex)"
      let projectName = "Harness \(projectIndex)"
      let projectDir = "/Users/example/Projects/harness-\(projectIndex)"
      let contextRoot =
        "/Users/example/Library/Application Support/harness/projects/\(projectId)"

      projects.append(
        ProjectSummary(
          projectId: projectId,
          name: projectName,
          projectDir: projectDir,
          contextRoot: contextRoot,
          activeSessionCount: sessionsPerProject,
          totalSessionCount: sessionsPerProject
        )
      )

      for sessionIndex in 0..<sessionsPerProject {
        let token = projectIndex * sessionsPerProject + sessionIndex
        let recordedAt = String(
          format: "2026-04-%02dT14:%02d:%02dZ",
          1 + (token % 27),
          (token * 3) % 60,
          (token * 7) % 60
        )
        let session = SessionSummary(
          projectId: projectId,
          projectName: projectName,
          projectDir: projectDir,
          contextRoot: contextRoot,
          checkoutId: "checkout-\(projectIndex)",
          checkoutRoot: projectDir,
          isWorktree: false,
          worktreeName: nil,
          sessionId: "session-\(projectIndex)-\(sessionIndex)",
          title: "Regression \(projectIndex)-\(sessionIndex)",
          context: "Regression lane \(projectIndex)-\(sessionIndex)",
          status: token.isMultiple(of: 5) ? .ended : .active,
          createdAt: recordedAt,
          updatedAt: recordedAt,
          lastActivityAt: recordedAt,
          leaderId: "leader-\(projectIndex)-\(sessionIndex)",
          observeId: token.isMultiple(of: 3) ? "observe-\(projectIndex)-\(sessionIndex)" : nil,
          pendingLeaderTransfer: nil,
          metrics: SessionMetrics(
            agentCount: 3,
            activeAgentCount: token.isMultiple(of: 5) ? 0 : 2,
            openTaskCount: token % 4,
            inProgressTaskCount: token % 3,
            blockedTaskCount: token % 2,
            completedTaskCount: token % 5
          )
        )
        sessions.append(session)
        detailsByID[session.sessionId] = makeSessionDetail(
          summary: session,
          workerID: "worker-\(projectIndex)-\(sessionIndex)",
          workerName: "Worker \(projectIndex)-\(sessionIndex)"
        )
      }
    }

    return PersistenceLargeSnapshotFixture(
      projects: projects,
      sessions: sessions,
      detailsByID: detailsByID
    )
  }

  func medianRuntimeMs(
    iterations: Int = 7,
    warmups: Int = 2,
    operation: @escaping () async throws -> Void
  ) async rethrows -> Double {
    for _ in 0..<warmups {
      try await operation()
    }

    var samples: [Double] = []
    samples.reserveCapacity(iterations)

    for _ in 0..<iterations {
      let startedAt = ContinuousClock.now
      try await operation()
      let duration = startedAt.duration(to: ContinuousClock.now)
      samples.append(durationMs(duration))
    }

    return samples.sorted()[samples.count / 2]
  }

  private func durationMs(_ duration: Duration) -> Double {
    let seconds = Double(duration.components.seconds) * 1_000
    let attoseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000
    return seconds + attoseconds
  }
}
