import Testing

@testable import HarnessMonitorKit

extension PreviewHarnessClientTaskBoardTests {
  @Test("Preview non-position updates preserve placement metadata")
  func previewNonPositionUpdatePreservesPlacementMetadata() {
    let item = taskBoardItem(
      externalRefs: [],
      lanePosition: 3,
      laneOrigin: .manual(actor: "daemon-control"),
      laneSetAt: "2026-07-22T14:00:00Z"
    )
    let updated = item.applyingPreviewUpdate(TaskBoardUpdateItemRequest(priority: .critical))

    #expect(updated.lanePosition == 3)
    #expect(updated.laneOrigin == .manual(actor: "daemon-control"))
    #expect(updated.laneSetAt == "2026-07-22T14:00:00Z")
  }

  @Test("Preview client returns task board audit and catalog summaries")
  func previewClientReturnsTaskBoardAuditAndCatalogSummaries() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )
    _ = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Ready item"))

    let audit = try await client.auditTaskBoard(status: nil)
    let projects = try await client.taskBoardProjects(status: nil)
    let machines = try await client.taskBoardMachines(status: nil)

    #expect(audit.total >= 1)
    #expect(audit.ready >= 1)
    #expect(!projects.isEmpty)
    #expect(!machines.isEmpty)
  }

  @Test("Preview external ref replacement preserves matching stored sync state")
  func previewExternalRefReplacementPreservesMatchingStoredSyncState() throws {
    let storedSyncState = TaskBoardExternalRefSyncState(status: .done)
    let item = taskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#42",
          url: "https://github.com/example/project/pull/42",
          syncState: storedSyncState
        )
      ]
    )

    let updated = item.applyingPreviewUpdate(
      TaskBoardUpdateItemRequest(
        externalRefs: [
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "example/project#42",
            url: "https://github.com/example/project/pull/42?view=files",
            syncState: TaskBoardExternalRefSyncState(status: .todo)
          )
        ]
      )
    )
    let replacement = try #require(updated.externalRefs.first)

    #expect(replacement.url == "https://github.com/example/project/pull/42?view=files")
    #expect(replacement.syncState == storedSyncState)
  }

  @Test("Preview external ref replacement rejects sync state for new identities")
  func previewExternalRefReplacementRejectsNewIdentitySyncState() {
    let item = taskBoardItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#42",
          syncState: TaskBoardExternalRefSyncState(status: .done)
        )
      ]
    )
    let clientSyncState = TaskBoardExternalRefSyncState(status: .todo)

    // Identity is (provider, externalId), so with one provider left the only way
    // to be a new identity is a differing externalId - casing included.
    let updated = item.applyingPreviewUpdate(
      TaskBoardUpdateItemRequest(
        externalRefs: [
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "EXAMPLE/PROJECT#42",
            syncState: clientSyncState
          ),
          TaskBoardExternalRef(
            provider: .gitHub,
            externalId: "example/project#43",
            syncState: clientSyncState
          ),
        ]
      )
    )

    #expect(updated.externalRefs.count == 2)
    #expect(updated.externalRefs.allSatisfy { $0.syncState == nil })
  }

  @Test("Preview external ref replacement distinguishes nil from empty")
  func previewExternalRefReplacementDistinguishesNilFromEmpty() {
    let refs = [
      TaskBoardExternalRef(
        provider: .gitHub,
        externalId: "example/project#42",
        syncState: TaskBoardExternalRefSyncState(status: .done)
      )
    ]
    let item = taskBoardItem(externalRefs: refs)

    let unchanged = item.applyingPreviewUpdate(TaskBoardUpdateItemRequest(status: .inProgress))
    let cleared = item.applyingPreviewUpdate(TaskBoardUpdateItemRequest(externalRefs: []))

    #expect(unchanged.externalRefs == refs)
    #expect(cleared.externalRefs.isEmpty)
  }

  @Test("A preview update re-resolves the item's project")
  func previewUpdateReresolvesTheItemsProject() {
    let original = taskBoardItem(externalRefs: []).applyingPreviewAttribution()
    let origin: String? = original.sourceProjectId
    #expect(origin != nil)

    let move = TaskBoardUpdateItemRequest(projectId: "acme/gadgets")
    let moved: String? = original.applyingPreviewUpdate(move).sourceProjectId
    #expect(moved != nil)
    #expect(moved != origin, "the item kept the project it left")

    let clear = TaskBoardUpdateItemRequest(clearProjectId: true)
    #expect(original.applyingPreviewUpdate(clear).sourceProjectId == nil)

    // A patch that leaves the project alone keeps the attribution it had.
    let rename = TaskBoardUpdateItemRequest(title: "Renamed")
    #expect(original.applyingPreviewUpdate(rename).sourceProjectId == origin)
  }

  func taskBoardItem(
    externalRefs: [TaskBoardExternalRef],
    lanePosition: UInt32? = nil,
    laneOrigin: TaskBoardLaneOrigin? = nil,
    laneSetAt: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "preview-external-ref-item",
      title: "Preview item",
      body: "Body",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: "example/project",
      agentMode: .interactive,
      externalRefs: externalRefs,
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: "2026-07-13T10:00:00Z",
      updatedAt: "2026-07-13T10:01:00Z",
      deletedAt: nil
    )
  }
}
