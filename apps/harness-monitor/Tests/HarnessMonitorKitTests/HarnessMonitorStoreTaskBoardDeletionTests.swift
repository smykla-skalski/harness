import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board deletion")
struct HarnessMonitorStoreTaskBoardDeletionTests {
  @Test("Deletion readiness matches every store guard")
  func deletionReadinessMatchesStoreGuard() async {
    let store = await makeBootstrappedStore()
    #expect(store.canDeleteTaskBoardTargets)

    store.beginTaskBoardAction()
    #expect(store.canDeleteTaskBoardTargets == false)
    store.endTaskBoardAction()

    store.beginDaemonAction()
    #expect(store.canDeleteTaskBoardTargets == false)
    store.endDaemonAction()

    store.connectionState = .offline("Unavailable for test")
    #expect(store.canDeleteTaskBoardTargets == false)

    let unavailableStore = HarnessMonitorStore(daemonController: RecordingDaemonController())
    unavailableStore.connectionState = .online
    #expect(unavailableStore.canDeleteTaskBoardTargets == false)
  }

  @Test("Deletion targets expose stable kind-scoped identities and titles")
  func deletionTargetsExposeStableIdentityAndTitle() throws {
    let boardItem = deletionBoardItem(id: "board-1", title: "Board draft")
    let inboxItem = try #require(
      TaskBoardInboxItem(session: PreviewFixtures.summary, task: PreviewFixtures.tasks[0])
    )

    let boardTarget = TaskBoardDeletionTarget(taskBoardItem: boardItem)
    let inboxTarget = TaskBoardDeletionTarget(inboxTask: inboxItem)

    #expect(boardTarget.id == "task-board-item:board-1")
    #expect(boardTarget.title == "Board draft")
    #expect(
      inboxTarget.id
        == "inbox-task:\(PreviewFixtures.summary.sessionId):\(PreviewFixtures.tasks[0].taskId)"
    )
    #expect(inboxTarget.title == PreviewFixtures.tasks[0].title)
  }

  @Test("Task Board confirmation submits deletion through the shared work queue")
  func confirmationUsesSharedWorkQueue() throws {
    let sourceURL = repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views/Shared/HarnessMonitorConfirmationDialogModifier.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("if case .deleteTaskBoardTargets(let targets)"))
    #expect(source.contains("HarnessMonitorAsyncWorkQueue.shared.submit("))
    #expect(source.contains("await store.confirmPendingAction(pendingConfirmation)"))
  }

  @Test("Deletion request keeps the first target for each stable identity")
  func deletionRequestDeduplicatesTargets() async {
    let store = await makeBootstrappedStore()
    let first = TaskBoardDeletionTarget.taskBoardItem(id: "board-1", title: "First title")
    let duplicate = TaskBoardDeletionTarget.taskBoardItem(
      id: "board-1",
      title: "Changed title"
    )
    let inbox = TaskBoardDeletionTarget.inboxTask(
      sessionID: "session-1",
      taskID: "task-1",
      title: "Session task"
    )

    store.requestTaskBoardDeletionConfirmation(targets: [first, duplicate, inbox])

    #expect(
      store.pendingConfirmation
        == .deleteTaskBoardTargets(targets: [first, inbox])
    )
    #expect(
      store.pendingConfirmation?.uiTestTraceLabel == "delete-task-board-targets"
    )
  }

  @Test("Deletion request is gated while another action is in progress")
  func deletionRequestRejectsBusyStore() async {
    let store = await makeBootstrappedStore()
    store.beginDaemonAction()
    #expect(store.canDeleteTaskBoardTargets == false)

    store.requestTaskBoardDeletionConfirmation(
      targets: [.taskBoardItem(id: "board-1", title: "Board draft")]
    )

    #expect(store.pendingConfirmation == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("already in progress") == true)
  }

  @Test("Deletion request is gated when persisted data is read-only")
  func deletionRequestRejectsReadOnlyStore() async {
    let store = await makeBootstrappedStore()
    store.connectionState = .offline("Unavailable for test")
    #expect(store.canDeleteTaskBoardTargets == false)

    store.requestTaskBoardDeletionConfirmation(
      targets: [.taskBoardItem(id: "board-1", title: "Board draft")]
    )

    #expect(store.pendingConfirmation == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("read-only mode") == true)
  }

  @Test("Deletion request requires a live daemon action channel")
  func deletionRequestRequiresActionChannel() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.connectionState = .online
    #expect(store.canDeleteTaskBoardTargets == false)

    store.requestTaskBoardDeletionConfirmation(
      targets: [.taskBoardItem(id: "board-1", title: "Board draft")]
    )

    #expect(store.pendingConfirmation == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("action channel") == true)
  }

  @Test("Confirmed board deletion performs sequential writes and one final refresh")
  func confirmedBoardDeletionUsesOneFinalRefresh() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      deletionBoardItem(id: "board-1", title: "First"),
      deletionBoardItem(id: "board-2", title: "Second"),
    ])
    let store = await makeBootstrappedStore(client: client)
    let baselineReads = client.readCallCount(.taskBoardItems(nil))

    store.requestTaskBoardDeletionConfirmation(
      targets: [
        .taskBoardItem(id: "board-1", title: "First"),
        .taskBoardItem(id: "board-2", title: "Second"),
      ]
    )
    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
    #expect(
      client.recordedCalls().filter(\.isTaskBoardDeletion)
        == [
          .deleteTaskBoardItem(id: "board-1"),
          .deleteTaskBoardItem(id: "board-2"),
        ]
    )
    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineReads + 1)
    #expect(store.globalTaskBoardItems.isEmpty)
    #expect(store.currentSuccessFeedbackMessage == "Deleted 2 tasks")
  }

  @Test("Board deletion stops honestly after the first failure and still refreshes once")
  func boardDeletionStopsAfterFirstFailure() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      deletionBoardItem(id: "board-1", title: "First"),
      deletionBoardItem(id: "board-3", title: "Third"),
    ])
    let store = await makeBootstrappedStore(client: client)
    let baselineReads = client.readCallCount(.taskBoardItems(nil))

    store.requestTaskBoardDeletionConfirmation(
      targets: [
        .taskBoardItem(id: "board-1", title: "First"),
        .taskBoardItem(id: "board-missing", title: "Missing"),
        .taskBoardItem(id: "board-3", title: "Third"),
      ]
    )
    await store.confirmPendingAction()

    #expect(
      client.recordedCalls().filter(\.isTaskBoardDeletion)
        == [
          .deleteTaskBoardItem(id: "board-1"),
          .deleteTaskBoardItem(id: "board-missing"),
        ]
    )
    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineReads + 1)
    #expect(store.globalTaskBoardItems.map(\.id) == ["board-3"])
    #expect(store.currentFailureFeedbackMessage?.contains("Deleted 1 of 3") == true)
    #expect(store.currentFailureFeedbackMessage?.contains("1 item was not attempted") == true)
  }

  @Test("Inbox deletions are grouped by session before reusing task cleanup")
  func inboxDeletionsAreGroupedBySession() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    store.requestTaskBoardDeletionConfirmation(
      targets: [
        .inboxTask(sessionID: "session-a", taskID: "task-a1", title: "A one"),
        .inboxTask(sessionID: "session-b", taskID: "task-b1", title: "B one"),
        .inboxTask(sessionID: "session-a", taskID: "task-a2", title: "A two"),
      ]
    )
    await store.confirmPendingAction()

    #expect(
      client.recordedCalls().filter(\.isSessionTaskDeletion)
        == [
          .deleteTask(sessionID: "session-a", taskID: "task-a1", actor: "harness-app"),
          .deleteTask(sessionID: "session-a", taskID: "task-a2", actor: "harness-app"),
          .deleteTask(sessionID: "session-b", taskID: "task-b1", actor: "harness-app"),
        ]
    )
    #expect(store.currentSuccessFeedbackMessage == "Deleted 3 tasks")
  }

  @Test("Mixed deletion stays board-busy through the inbox phase")
  func mixedDeletionStaysBoardBusyThroughInboxPhase() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      deletionBoardItem(id: "board-1", title: "Board draft")
    ])
    client.configureMutationDelay(.milliseconds(200))
    let store = await makeBootstrappedStore(client: client)
    store.stopAllStreams()
    let baselineReads = client.readCallCount(.taskBoardItems(nil))
    let inboxTask = PreviewFixtures.tasks[0]

    let deletion = Task { @MainActor in
      await store.deleteTaskBoardTargets([
        .taskBoardItem(id: "board-1", title: "Board draft"),
        .inboxTask(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: inboxTask.taskId,
          title: inboxTask.title
        ),
      ])
    }

    for _ in 0..<100 {
      if client.readCallCount(.taskBoardItems(nil)) > baselineReads {
        break
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    await Task.yield()

    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineReads + 1)
    #expect(store.globalTaskBoardItems.isEmpty)
    #expect(store.isTaskBoardBusy)

    let success = await deletion.value
    #expect(success)
    #expect(store.isTaskBoardBusy == false)
  }

  private func deletionBoardItem(id: String, title: String) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: "Body",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-12T10:00:00Z",
      updatedAt: "2026-07-12T10:00:00Z",
      deletedAt: nil
    )
  }
}

extension RecordingHarnessClient.Call {
  fileprivate var isTaskBoardDeletion: Bool {
    if case .deleteTaskBoardItem = self { return true }
    return false
  }

  fileprivate var isSessionTaskDeletion: Bool {
    if case .deleteTask = self { return true }
    return false
  }
}
