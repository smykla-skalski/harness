import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task board inbox snapshot decode")
@MainActor
struct TaskBoardInboxSnapshotDecodeTests {
  @Test("Duplicate session IDs do not trap")
  func duplicateSessionIDsDoNotTrap() {
    let first = makeSession(
      SessionFixture(
        sessionId: "sess-dup",
        title: "First",
        context: "First",
        status: .active,
        leaderId: "leader-a",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1,
        lastActivityAt: "2026-05-15T01:00:00Z"
      )
    )
    let second = makeSession(
      SessionFixture(
        sessionId: "sess-dup",
        title: "Second",
        context: "Second",
        status: .active,
        leaderId: "leader-b",
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 2,
        lastActivityAt: "2026-05-15T02:00:00Z"
      )
    )
    let detail = SessionDetail(
      session: first,
      agents: [],
      tasks: [
        WorkItem(
          taskId: "task-1",
          title: "Task one",
          context: nil,
          severity: .medium,
          status: .open,
          assignedTo: "worker-1",
          queuedAt: nil,
          createdAt: "2026-05-15T00:00:00Z",
          updatedAt: "2026-05-15T01:30:00Z",
          createdBy: nil,
          notes: [],
          suggestedFix: nil,
          source: .manual,
          blockedReason: nil,
          completedAt: nil,
          checkpointSummary: nil
        )
      ],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    let snapshot = TaskBoardInboxSnapshot(
      sessions: [first, second],
      detailsBySessionID: [first.sessionId: detail]
    )

    #expect(snapshot.items.count == 1)
    let item = snapshot.items.first
    #expect(item?.task.taskId == "task-1")
    #expect(item?.session.sessionId == "sess-dup")
    #expect(item?.session.title == "First")
  }

  @Test("Session lookup keeps the first entry on collision")
  func sessionLookupKeepsFirstEntryOnCollision() {
    let first = makeSession(
      SessionFixture(
        sessionId: "sess-dup",
        title: "First",
        context: "First",
        status: .active,
        leaderId: "leader-a",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1,
        lastActivityAt: "2026-05-15T01:00:00Z"
      )
    )
    let second = makeSession(
      SessionFixture(
        sessionId: "sess-dup",
        title: "Second",
        context: "Second",
        status: .active,
        leaderId: "leader-b",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1,
        lastActivityAt: "2026-05-15T02:00:00Z"
      )
    )

    let lookup = TaskBoardInboxSnapshot.sessionLookup([first, second])

    #expect(lookup.count == 1)
    #expect(lookup["sess-dup"]?.title == "First")
  }
}
