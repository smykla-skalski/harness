import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board item editor draft")
struct TaskBoardItemEditorDraftTests {
  @Test("Create request normalizes board-only editor fields")
  func createRequestNormalizesBoardOnlyEditorFields() {
    var draft = TaskBoardItemEditorDraft()
    draft.title = "  Build editor  "
    draft.body = "  Body  "
    draft.status = .todo
    draft.priority = .critical
    draft.tagsText = " ui, monitor, , "
    draft.projectId = " project-1 "
    draft.agentMode = .planning
    draft.planningSummary = " Write the plan "
    draft.externalRefs = [
      TaskBoardExternalRefDraft(ref: TaskBoardExternalRef(provider: .todoist, externalId: "T-1"))
    ]

    let request = draft.createRequest

    #expect(request.title == "Build editor")
    #expect(request.body == "Body")
    #expect(request.priority == .critical)
    #expect(request.tags == ["ui", "monitor"])
    #expect(request.projectId == "project-1")
    #expect(request.agentMode == .planning)
    #expect(request.planning.summary == "Write the plan")
    #expect(request.externalRefs.first?.provider == .todoist)
    #expect(request.externalRefs.first?.externalId == "T-1")
  }

  @Test("Create request carries target project types from draft")
  func createRequestCarriesTargetProjectTypes() {
    var draft = TaskBoardItemEditorDraft()
    draft.title = "Routed"
    draft.targetProjectTypes = ["web", "data"]

    let request = draft.createRequest

    #expect(request.targetProjectTypes == ["web", "data"])
  }

  @Test("Update request carries target project types from draft")
  func updateRequestCarriesTargetProjectTypes() {
    var draft = TaskBoardItemEditorDraft(item: sampleTaskBoardItem())
    draft.targetProjectTypes = ["mobile"]

    let request = draft.updateRequest

    #expect(request.targetProjectTypes == ["mobile"])
  }

  @Test("Monitor public UI hides Todoist provider choices")
  func monitorPublicUIHidesTodoistProviderChoices() {
    #expect(TaskBoardExternalProviderChoice.monitorVisibleChoice == .gitHub)
    #expect(TaskBoardExternalRefProvider.taskBoardCases == [.gitHub])
  }

  @Test("Status menus expose only current task board lanes")
  func statusMenusExposeOnlyCurrentTaskBoardLanes() {
    let expectedFilterTitles = [
      "All Items",
      "Backlog",
      "Todo",
      "Planning",
      "In Progress",
      "Agentic Review",
      "Testing",
      "In Review",
      "To Review",
      "Human Required",
      "Failed",
    ]

    #expect(
      TaskBoardStatus.currentLaneCases.map(\.title)
        == Array(expectedFilterTitles.dropFirst())
    )
    #expect(TaskBoardStatusFilterChoice.stableAllCases.map(\.title) == expectedFilterTitles)
    #expect(DispatchStatusFilterChoice.allCases.map(\.title) == expectedFilterTitles)
  }

  @Test("Status picker renders a tag for a closed item whose status has no lane")
  func statusPickerRendersSelectionOutsideLaneCases() {
    // A done item seeds `.done`, which `currentLaneCases` omits because it maps
    // to no lane and `canonicalPersistedStatus` leaves it unchanged. The picker
    // must still render it, or SwiftUI logs "the selection \"done\" is invalid
    // and does not have an associated tag" and the control shows no value.
    let withDone = taskBoardManagementPickerValues(
      TaskBoardStatus.currentLaneCases,
      selection: .done
    )
    #expect(withDone == TaskBoardStatus.currentLaneCases + [.done])

    let withOfferedValue = taskBoardManagementPickerValues(
      TaskBoardStatus.currentLaneCases,
      selection: .todo
    )
    #expect(withOfferedValue == TaskBoardStatus.currentLaneCases)
  }

  @Test("Legacy statuses seed current picker-compatible draft values")
  func legacyStatusesSeedCurrentPickerCompatibleDraftValues() {
    #expect(TaskBoardItemEditorDraft(item: sampleTaskBoardItem(status: .new)).status == .todo)
    #expect(
      TaskBoardItemEditorDraft(item: sampleTaskBoardItem(status: .planReview)).status
        == .agenticReview)
    #expect(
      TaskBoardItemEditorDraft(item: sampleTaskBoardItem(status: .needsYou)).status
        == .humanRequired)
    #expect(TaskBoardItemEditorDraft(item: sampleTaskBoardItem(status: .blocked)).status == .failed)

    #expect(TaskBoardStatusFilterChoice(status: .new) == .todo)
    #expect(TaskBoardStatusFilterChoice(status: .planReview) == .agenticReview)
    #expect(TaskBoardStatusFilterChoice(status: .needsYou) == .humanRequired)
    #expect(TaskBoardStatusFilterChoice(status: .blocked) == .failed)
    #expect(DispatchStatusFilterChoice(status: .new) == .todo)
    #expect(DispatchStatusFilterChoice(status: .planReview) == .agenticReview)
    #expect(DispatchStatusFilterChoice(status: .needsYou) == .humanRequired)
    #expect(DispatchStatusFilterChoice(status: .blocked) == .failed)
  }

  @Test("Monitor public UI hides Todoist sync summaries")
  func monitorPublicUIHidesTodoistSyncSummaries() {
    let summary = TaskBoardSyncSummary(
      total: 2,
      providers: [
        TaskBoardProviderSyncSummary(
          provider: .gitHub,
          configured: true,
          linked: 1,
          pushable: 1,
          blocked: 0,
          tokenEnv: []
        ),
        TaskBoardProviderSyncSummary(
          provider: .todoist,
          configured: true,
          linked: 1,
          pushable: 0,
          blocked: 0,
          tokenEnv: []
        ),
      ],
      operations: [
        TaskBoardExternalSyncOperation(
          provider: .gitHub,
          action: .pull,
          boardItemId: "board-1",
          dryRun: true,
          applied: false
        ),
        TaskBoardExternalSyncOperation(
          provider: .todoist,
          action: .push,
          externalId: "todo-1",
          dryRun: true,
          applied: false
        ),
      ]
    )

    #expect(summary.monitorVisibleProviders.map(\.provider) == [.gitHub])
    #expect(summary.monitorVisibleOperations.map(\.provider) == [.gitHub])
  }

  @Test("Draft seeds target project types from item")
  func draftSeedsTargetProjectTypesFromItem() {
    let item = sampleTaskBoardItem(targetProjectTypes: ["web"])

    let draft = TaskBoardItemEditorDraft(item: item)

    #expect(draft.targetProjectTypes == ["web"])
  }

  @Test("Update request clears optional links and preserves approval readout")
  func updateRequestClearsOptionalLinksAndPreservesApprovalReadout() {
    var draft = TaskBoardItemEditorDraft(item: sampleTaskBoardItem())
    draft.projectId = " "
    draft.sessionId = " "
    draft.workItemId = " "
    draft.planningSummary = " Updated plan "

    let request = draft.updateRequest

    #expect(request.clearProjectId)
    #expect(request.clearSessionId)
    #expect(request.clearWorkItemId)
    #expect(request.planning?.summary == "Updated plan")
    #expect(request.planning?.approvedBy == "lead")
    #expect(request.planning?.approvedAt == "2026-05-14T10:00:00Z")
  }

  @Test("Monitor hides Todoist refs while unchanged update preserves server refs")
  func monitorHidesTodoistRefsWhileUnchangedUpdatePreservesServerRefs() {
    let item = sampleTaskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .todoist,
          externalId: "todo-1",
          url: "https://todoist.com/showTask?id=todo-1"
        ),
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "42",
          url: "https://github.com/example/project/pull/42",
          syncState: TaskBoardExternalRefSyncState(status: .done)
        ),
      ]
    )

    let draft = TaskBoardItemEditorDraft(item: item)

    #expect(draft.monitorVisibleExternalRefIDs == [draft.externalRefs[1].id])
    #expect(draft.monitorVisibleExternalRefs.map(\.provider) == [.gitHub])
    #expect(draft.updateRequest.externalRefs == nil)
  }

  @Test("Editing an external ref sends a replacement vector")
  func editingExternalRefSendsReplacementVector() throws {
    var draft = TaskBoardItemEditorDraft(
      item: sampleTaskBoardItem(
        externalRefs: [
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "42",
            url: "https://github.com/example/project/pull/42",
            syncState: TaskBoardExternalRefSyncState(status: .done)
          )
        ]
      )
    )
    draft.externalRefs[0].externalId = "43"
    draft.externalRefs[0].url = "https://github.com/example/project/pull/43"

    let refs = try #require(draft.updateRequest.externalRefs)

    #expect(refs.map(\.externalId) == ["43"])
    #expect(refs.first?.syncState == nil)
  }

  @Test("External ref replacement leaves sync state daemon-owned")
  func externalRefReplacementLeavesSyncStateDaemonOwned() throws {
    var draft = TaskBoardItemEditorDraft(
      item: sampleTaskBoardItem(
        externalRefs: [
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "issue-12",
            url: "https://github.com/example/project/issues/12"
          ),
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "review-42",
            url: "https://github.com/example/project/pull/42",
            syncState: TaskBoardExternalRefSyncState(status: .done)
          ),
        ]
      )
    )
    draft.externalRefs[0].externalId = "issue-13"
    draft.externalRefs[0].url = "https://github.com/example/project/issues/13"

    let refs = try #require(draft.updateRequest.externalRefs)

    #expect(refs[0].syncState == nil)
    #expect(refs[1].syncState == nil)
  }

  private func sampleTaskBoardItem(
    status: TaskBoardStatus = .todo,
    targetProjectTypes: [String] = [],
    externalRefs: [TaskBoardExternalRef] = []
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-1",
      title: "Board item",
      body: "Body",
      status: status,
      priority: .high,
      tags: ["automation"],
      projectId: "project-1",
      targetProjectTypes: targetProjectTypes,
      agentMode: .interactive,
      externalRefs: externalRefs,
      planning: TaskBoardPlanningState(
        summary: "Approved plan",
        approvedBy: "lead",
        approvedAt: "2026-05-14T10:00:00Z"
      ),
      workflow: nil,
      sessionId: "sess-1",
      workItemId: "task-1",
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
