import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board dashboard")
struct HarnessMonitorStoreTaskBoardDashboardTests {
  @Test("Refresh task board dashboard imports external items with applied pull sync")
  func refreshTaskBoardDashboardImportsExternalItemsWithAppliedPullSync() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([])
    client.configureTaskBoardSync(
      summary: TaskBoardSyncSummary(
        total: 1,
        providers: [],
        operations: [
          TaskBoardExternalSyncOperation(
            provider: .gitHub,
            action: .pull,
            boardItemId: "board-1",
            externalId: "123",
            url: "https://example.invalid/issues/123",
            dryRun: false,
            applied: true
          )
        ]
      ),
      importedItems: [sampleTaskBoardItem()]
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCalls = client.readCallCount(.taskBoardItems(nil))

    await store.refreshTaskBoardDashboard()

    #expect(
      client.recordedCalls().contains(
        .syncTaskBoard(direction: .pull, dryRun: false, status: nil, provider: nil)
      )
    )
    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineCalls + 1)
    #expect(store.globalTaskBoardItems.first?.id == "board-1")
    #expect(store.globalTaskBoardItems.first?.externalRefs.first?.provider == .gitHub)
    #expect(store.globalTaskBoardSyncSummary?.operations.first?.boardItemId == "board-1")
    #expect(store.contentUI.dashboard.taskBoardItems.first?.id == "board-1")
    #expect(store.contentUI.dashboard.taskBoardSyncSummary?.total == 1)
  }

  @Test("Refreshing the dashboard fills the project catalog the card marks read")
  func refreshingDashboardFillsProjectCatalog() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      sampleTaskBoardItem(
        id: "board-1", status: .todo, agentMode: .interactive, projectId: "project-1")
    ])
    let store = await makeBootstrappedStore(client: client)

    // No Settings visit and no explicit refreshTaskBoardProjects: a card's
    // project mark has to survive an ordinary board load.
    await store.refreshTaskBoardDashboard()

    #expect(client.recordedCalls().contains(.taskBoardProjects(status: nil)))
    #expect(store.globalTaskBoardProjects?.isEmpty == false)
    #expect(store.contentUI.dashboard.taskBoardProjects?.isEmpty == false)
  }

  @Test("Connecting fills the project catalog before any board refresh")
  func connectingFillsProjectCatalog() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      sampleTaskBoardItem(
        id: "board-1", status: .todo, agentMode: .interactive, projectId: "project-1")
    ])

    // Startup loads the board through its own snapshot, so a card opened right
    // after launch has to be marked without waiting for a mutation to schedule
    // the dashboard refresh.
    let store = await makeBootstrappedStore(client: client)

    #expect(store.globalTaskBoardProjects?.isEmpty == false)
    #expect(store.contentUI.dashboard.taskBoardProjects?.isEmpty == false)
  }

  @Test("An unavailable project catalog keeps the marks already on screen")
  func unavailableProjectCatalogKeepsExistingMarks() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      sampleTaskBoardItem(
        id: "board-1", status: .todo, agentMode: .interactive, projectId: "project-1")
    ])
    let store = await makeBootstrappedStore(client: client)
    await store.refreshTaskBoardDashboard()
    let loaded = store.globalTaskBoardProjects

    client.configureTaskBoardProjectsErrors([
      HarnessMonitorAPIError.server(code: 503, message: "projects unavailable")
    ])
    await store.refreshTaskBoardDashboard()

    #expect(loaded?.isEmpty == false)
    #expect(store.globalTaskBoardProjects == loaded)
  }

  @Test("Evaluate task board records the summary and refreshes dashboard state")
  func evaluateTaskBoardRecordsSummaryAndRefreshesDashboardState() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.evaluateTaskBoard(status: .inProgress, dryRun: true)

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .evaluateTaskBoard(dryRun: true, status: .inProgress, itemID: nil)
      )
    )
    #expect(store.globalTaskBoardEvaluationSummary?.updated == 1)
    #expect(store.contentUI.dashboard.taskBoardEvaluationSummary?.updated == 1)
    #expect(store.currentSuccessFeedbackMessage == "Evaluated task board")
  }

  @Test("Evaluate task board can target one board item")
  func evaluateTaskBoardCanTargetOneBoardItem() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.evaluateTaskBoard(
      status: .todo,
      itemID: "board-1",
      dryRun: false
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .evaluateTaskBoard(dryRun: false, status: .todo, itemID: "board-1")
      )
    )
    #expect(store.globalTaskBoardEvaluationSummary?.records.first?.boardItemId == "board-1")
  }

  @Test("Dispatch task board can apply one board item and refresh dashboard state")
  func dispatchTaskBoardCanApplyOneBoardItemAndRefreshDashboardState() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.dispatchTaskBoard(
      request: TaskBoardDispatchRequest(itemId: "board-1", dryRun: false)
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .dispatchTaskBoard(
          dryRun: false,
          status: nil,
          itemID: "board-1",
          projectDir: nil,
          actor: nil
        )
      )
    )
    #expect(store.globalTaskBoardDispatchSummary?.applied.map(\.boardItemId) == ["board-1"])
    #expect(store.contentUI.dashboard.taskBoardDispatchSummary?.applied.count == 1)
    #expect(store.globalTaskBoardItems.first?.status == .inProgress)
    #expect(store.currentSuccessFeedbackMessage == "Dispatched task board")
  }

  @Test("Step-mode prepare+deliver completes with a single success when delivery starts the worker")
  func stepModePrepareAndDeliverCompletesWithOneSuccess() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    client.configureHeldTaskBoardDispatches(["board-1"])
    let store = await makeBootstrappedStore(client: client)

    let delivery = await store.prepareAndDeliverTaskBoardDispatch(
      request: TaskBoardDispatchRequest(itemId: "board-1", dryRun: false)
    )

    #expect(delivery != nil)
    #expect(store.currentSuccessFeedbackMessage == "Prepared and delivered task-board item")
    #expect(store.currentFailureFeedbackMessage == nil)
    // The reserve must not stand as a finished dispatch of its own.
    #expect(store.globalTaskBoardDispatchSummary == nil)
    #expect(
      client.recordedCalls().contains(.deliverTaskBoardDispatch(itemID: "board-1", dryRun: false))
    )
  }

  @Test("Step-mode prepare+deliver reports one outcome when the held claim fails")
  func stepModePrepareAndDeliverReportsSingleOutcomeWhenClaimFails() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    client.configureHeldTaskBoardDispatches(["board-1"])
    // The hold is claimed out from under the delivery between the check and
    // the claim, which is the one race the daemon still has to answer for.
    client.configureDeliverTaskBoardDispatchErrors([
      HarnessMonitorAPIError.server(
        code: 409,
        message: "task-board dispatch for item 'board-1' has no held delivery to claim"
      )
    ])
    let store = await makeBootstrappedStore(client: client)

    let delivery = await store.prepareAndDeliverTaskBoardDispatch(
      request: TaskBoardDispatchRequest(itemId: "board-1", dryRun: false)
    )

    #expect(delivery == nil)
    // No success toast or finished-dispatch record may stand next to the failure.
    #expect(store.globalTaskBoardDispatchSummary == nil)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("no held delivery to claim") == true)
    #expect(
      client.recordedCalls().contains(
        .dispatchTaskBoard(
          dryRun: false,
          status: nil,
          itemID: "board-1",
          projectDir: nil,
          actor: nil
        )
      )
    )
  }

  @Test("Step-mode prepare+deliver never claims a delivery the daemon is not holding")
  func stepModePrepareAndDeliverSkipsClaimWhenNothingIsHeld() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    // The daemon holds nothing: its own step mode was off, so the reserve
    // started the worker outright instead of parking a held delivery.
    let store = await makeBootstrappedStore(client: client)

    let delivery = await store.prepareAndDeliverTaskBoardDispatch(
      request: TaskBoardDispatchRequest(itemId: "board-1", dryRun: false)
    )

    #expect(delivery == nil)
    #expect(store.currentSuccessFeedbackMessage == "Dispatched task-board item")
    #expect(store.currentFailureFeedbackMessage == nil)
    // Claiming anyway is exactly what produced the "is not held" conflict.
    #expect(
      !client.recordedCalls().contains(.deliverTaskBoardDispatch(itemID: "board-1", dryRun: false))
    )
  }

  @Test("Step-mode prepare+deliver reports a clean failure when the reserve took no item")
  func stepModePrepareAndDeliverFailsCleanlyWhenReserveTookNoItem() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    // Nothing reserves "board-2", so there is no hold and no started worker.
    let delivery = await store.prepareAndDeliverTaskBoardDispatch(
      request: TaskBoardDispatchRequest(itemId: "board-2", dryRun: false)
    )

    #expect(delivery == nil)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("No held delivery to claim") == true)
    #expect(
      !client.recordedCalls().contains(.deliverTaskBoardDispatch(itemID: "board-2", dryRun: false))
    )
  }

  @Test("Step-mode prepare+deliver surfaces the reserve failure reason over the generic message")
  func stepModePrepareAndDeliverSurfacesReserveFailureReason() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    // The daemon reserves nothing for board-2 and reports the real reason why -
    // here the missing project dir that a create-session dispatch requires.
    let reason = "task-board dispatch requires project_dir when a session must be created"
    client.configureTaskBoardDispatchFailure(itemID: "board-2", message: reason)
    let store = await makeBootstrappedStore(client: client)

    let delivery = await store.prepareAndDeliverTaskBoardDispatch(
      request: TaskBoardDispatchRequest(itemId: "board-2", dryRun: false)
    )

    #expect(delivery == nil)
    #expect(store.currentSuccessFeedbackMessage == nil)
    // The real reserve failure reaches the toast instead of "No held delivery to claim".
    #expect(store.currentFailureFeedbackMessage == reason)
    #expect(
      !client.recordedCalls().contains(.deliverTaskBoardDispatch(itemID: "board-2", dryRun: false))
    )
  }

  @Test("Dispatch summary decodes when the daemon omits an empty failures list")
  func dispatchSummaryDecodesWithoutFailuresKey() throws {
    // The daemon skips serializing an empty failures list and older payloads
    // predate the field, so a missing key must decode as no failures.
    let json = Data(#"{"plans": [], "applied": []}"#.utf8)
    let summary = try JSONDecoder().decode(TaskBoardDispatchSummary.self, from: json)
    #expect(summary.failures.isEmpty)
    #expect(summary.applied.isEmpty)
  }

  @Test("Audit, projects, and machines summaries update dashboard state")
  func auditProjectsAndMachinesUpdateDashboardState() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      sampleTaskBoardItem(
        id: "board-1", status: .todo, agentMode: .interactive, projectId: "project-1"),
      sampleTaskBoardItem(
        id: "board-2", status: .failed, agentMode: .planning, projectId: "project-2"),
    ])
    let store = await makeBootstrappedStore(client: client)

    let audited = await store.auditTaskBoard()
    let loadedProjects = await store.refreshTaskBoardProjects()
    let loadedMachines = await store.refreshTaskBoardMachines()

    #expect(audited)
    #expect(loadedProjects)
    #expect(loadedMachines)
    #expect(client.recordedCalls().contains(.auditTaskBoard(status: nil)))
    #expect(client.recordedCalls().contains(.taskBoardProjects(status: nil)))
    #expect(client.recordedCalls().contains(.taskBoardMachines(status: nil)))
    #expect(store.globalTaskBoardItemAuditSummary?.total == 2)
    #expect(store.contentUI.dashboard.taskBoardItemAuditSummary?.blocked == 1)
    #expect(store.globalTaskBoardProjects?.count == 2)
    #expect(store.contentUI.dashboard.taskBoardProjects?.count == 2)
    #expect(store.globalTaskBoardMachines?.count == 2)
    #expect(store.contentUI.dashboard.taskBoardMachines?.count == 2)
  }

  @Test("Moving a task board item updates status through the daemon")
  func movingTaskBoardItemUpdatesStatusThroughDaemon() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.updateTaskBoardItemStatus(id: "board-1", status: .inProgress)

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .updateTaskBoardItem(id: "board-1", status: .inProgress)
      )
    )
    #expect(store.globalTaskBoardItems.first?.status == .inProgress)
    #expect(store.contentUI.dashboard.taskBoardItems.first?.status == .inProgress)
    #expect(store.currentSuccessFeedbackMessage == "Moved task board item")
  }

}
