import Foundation

@testable import HarnessMonitorKit

actor TaskBoardStatusActionBarrier {
  private var entered = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func enterAndWait() async {
    entered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      enteredContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

extension HarnessMonitorStoreTaskBoardStatusUpdateTests {
  func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    kind: TaskBoardItemKind = .task,
    lanePosition: UInt32? = nil,
    laneOrigin: TaskBoardLaneOrigin? = nil,
    laneSetAt: String? = nil,
    sourceProjectId: String? = nil,
    executionRepository: String? = nil,
    workflow: TaskBoardWorkflowState? = nil,
    sessionId: String? = nil,
    workItemId: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: .high,
      tags: ["automation"],
      projectId: "project-1",
      sourceProjectId: sourceProjectId,
      executionRepository: executionRepository,
      agentMode: .interactive,
      kind: kind,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: workflow,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: TaskBoardUsage(),
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
