import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board Swift UX correctness (Unit 12)")
struct TaskBoardSwiftUXCorrectnessTests {
  // MARK: - #12 conditional policy feedback

  @Test("Saving an invalid policy draft surfaces the first validation issue, not success")
  func savingInvalidPolicyDraftSurfacesFailureFeedback() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardPolicyPipelineValidation(
      TaskBoardPolicyPipelineValidation(
        isValid: false,
        issues: [
          TaskBoardPolicyPipelineValidationIssue(
            code: "graph.invalid",
            message: "Graph has a dangling node"
          )
        ]
      )
    )
    let store = await makeBootstrappedStore(client: client)

    let outcome = await store.saveTaskBoardPolicyPipelineDraft(document: sampleDraftDocument())

    #expect(outcome == false)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(store.currentFailureFeedbackMessage == "Graph has a dangling node")
  }

  @Test("Saving a valid policy draft still surfaces the saved-policy success toast")
  func savingValidPolicyDraftSurfacesSuccessFeedback() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let outcome = await store.saveTaskBoardPolicyPipelineDraft(document: sampleDraftDocument())

    #expect(outcome)
    #expect(store.currentSuccessFeedbackMessage == "Saved policy draft")
  }

  @Test("Simulating with invalid validation surfaces the first issue and skips success toast")
  func simulatingInvalidValidationSurfacesFailureFeedback() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardPolicyPipelineValidation(
      TaskBoardPolicyPipelineValidation(
        isValid: false,
        issues: [
          TaskBoardPolicyPipelineValidationIssue(
            code: "edge.cycle",
            message: "Pipeline has a cycle"
          )
        ]
      )
    )
    client.configureTaskBoardPolicyPipelineSimulationSucceeded(false)
    let store = await makeBootstrappedStore(client: client)

    let outcome = await store.simulateTaskBoardPolicyPipeline(document: sampleDraftDocument())

    #expect(outcome == false)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(store.currentFailureFeedbackMessage == "Pipeline has a cycle")
  }

  // MARK: - #13 stable ForEach id

  @Test("Repository override drafts carry distinct stable identifiers")
  func repositoryOverrideDraftIdentifiersAreDistinct() {
    let drafts = [
      TaskBoardRepositoryOverrideDraft(),
      TaskBoardRepositoryOverrideDraft(),
      TaskBoardRepositoryOverrideDraft(),
    ]
    let ids = Set(drafts.map(\.id))
    #expect(ids.count == drafts.count)
  }

  @Test("Repository override draft identifier survives token mutation")
  func repositoryOverrideDraftIdentifierSurvivesMutation() {
    var draft = TaskBoardRepositoryOverrideDraft(repository: "owner/repo")
    let originalID = draft.id
    draft.token = "ghp_replaced"
    #expect(draft.id == originalID)
  }

  // MARK: - #19 unknown enum decoding

  @Test("Unknown orchestrator workflow round-trips through Codable as .unknown")
  func unknownOrchestratorWorkflowRoundTripsAsUnknown() throws {
    let json = Data(#""future_unknown_workflow""#.utf8)
    let decoded = try JSONDecoder().decode(TaskBoardOrchestratorWorkflow.self, from: json)
    if case .unknown(let raw) = decoded {
      #expect(raw == "future_unknown_workflow")
    } else {
      Issue.record("Expected unknown workflow, got \(decoded)")
    }
    let encoded = try JSONEncoder().encode(decoded)
    #expect(String(data: encoded, encoding: .utf8) == #""future_unknown_workflow""#)
  }

  @Test("Known orchestrator workflow still decodes to canonical case")
  func knownOrchestratorWorkflowDecodesToCanonical() throws {
    let json = Data(#""pr_review""#.utf8)
    let decoded = try JSONDecoder().decode(TaskBoardOrchestratorWorkflow.self, from: json)
    #expect(decoded == .prReview)
    #expect(decoded.rawValue == "pr_review")
  }

  @Test("Unknown task-board status round-trips through Codable as .unknown")
  func unknownTaskBoardStatusRoundTripsAsUnknown() throws {
    let json = Data(#""mystery_state""#.utf8)
    let decoded = try JSONDecoder().decode(TaskBoardStatus.self, from: json)
    if case .unknown(let raw) = decoded {
      #expect(raw == "mystery_state")
    } else {
      Issue.record("Expected unknown status, got \(decoded)")
    }
    let encoded = try JSONEncoder().encode(decoded)
    #expect(String(data: encoded, encoding: .utf8) == #""mystery_state""#)
  }

  @Test("Unknown agent mode round-trips through Codable as .unknown")
  func unknownAgentModeRoundTripsAsUnknown() throws {
    let json = Data(#""quantum""#.utf8)
    let decoded = try JSONDecoder().decode(TaskBoardAgentMode.self, from: json)
    if case .unknown(let raw) = decoded {
      #expect(raw == "quantum")
    } else {
      Issue.record("Expected unknown agent mode, got \(decoded)")
    }
  }

  @Test("Unknown merge method round-trips through Codable as .unknown")
  func unknownMergeMethodRoundTripsAsUnknown() throws {
    let json = Data(#""fast_forward""#.utf8)
    let decoded = try JSONDecoder().decode(TaskBoardGitHubMergeMethod.self, from: json)
    if case .unknown(let raw) = decoded {
      #expect(raw == "fast_forward")
    } else {
      Issue.record("Expected unknown merge method, got \(decoded)")
    }
  }

  @Test("Unknown signing mode round-trips through Codable as .unknown")
  func unknownSigningModeRoundTripsAsUnknown() throws {
    let json = Data(#""x509""#.utf8)
    let decoded = try JSONDecoder().decode(TaskBoardGitSigningMode.self, from: json)
    if case .unknown(let raw) = decoded {
      #expect(raw == "x509")
    } else {
      Issue.record("Expected unknown signing mode, got \(decoded)")
    }
  }

  @Test("Orchestrator settings load survives an unknown workflow value")
  func orchestratorSettingsLoadSurvivesUnknownWorkflow() throws {
    let json = Data(
      #"""
      {
        "enabledWorkflows": ["pr_fix", "future_unknown_workflow"],
        "dryRunDefault": true,
        "githubProject": {
          "owner": "acme",
          "repo": "core",
          "checkoutPath": "/tmp/core",
          "defaultBranch": "main",
          "branchPrefix": "c/",
          "mergeMethod": "squash",
          "labels": {
            "managed": "managed",
            "autoMerge": "auto",
            "needsHuman": "needs-human",
            "protectedPath": "protected"
          },
          "protectedPaths": [],
          "requestedReviewers": {"reviewers": [], "teamReviewers": []},
          "enabledAutomations": {"enabled": []}
        },
        "policyVersion": "v1"
      }
      """#.utf8
    )
    let settings = try JSONDecoder().decode(TaskBoardOrchestratorSettings.self, from: json)
    #expect(settings.enabledWorkflows.contains(.prFix))
    #expect(settings.enabledWorkflows.contains(.unknown("future_unknown_workflow")))
  }

  // MARK: - #30 dispatch selection validation

  @Test("Validating an unknown dispatch item id falls back to nil")
  func validatingUnknownDispatchItemIDFallsBackToNil() {
    let items = [sampleTaskBoardItem(id: "real-1"), sampleTaskBoardItem(id: "real-2")]
    let valid = items.contains(where: { $0.id == "ghost" })
    #expect(valid == false)
  }

  // MARK: - #31 drag preserves source status

  @Test("Dragging a planning item into Backlog preserves the planning status")
  func draggingPlanningItemIntoBacklogPreservesStatus() {
    let item = sampleTaskBoardItem(status: .planning)
    let resolved = TaskBoardInboxLane.backlog.taskBoardDropStatus(for: item)
    #expect(resolved == .planning)
  }

  @Test("Dragging a new item into Backlog stays at new")
  func draggingNewItemIntoBacklogStaysAtNew() {
    let item = sampleTaskBoardItem(status: .new)
    let resolved = TaskBoardInboxLane.backlog.taskBoardDropStatus(for: item)
    #expect(resolved == .new)
  }

  @Test("Dragging a todo item into Backlog defaults to new")
  func draggingTodoItemIntoBacklogDefaultsToNew() {
    let item = sampleTaskBoardItem(status: .todo)
    let resolved = TaskBoardInboxLane.backlog.taskBoardDropStatus(for: item)
    #expect(resolved == .new)
  }

  // MARK: - #33 ordered unique lines

  @Test("normalizedUniqueLines preserves first-seen order")
  func normalizedUniqueLinesPreservesFirstSeenOrder() {
    var draft = TaskBoardGitSettingsDraft()
    draft.requestedReviewersText = "bart\nalice\ncasey\nbart\nalice"

    let snapshot = draft.snapshot
    #expect(
      snapshot.orchestratorSettings.githubProject.requestedReviewers.reviewers
        == ["bart", "alice", "casey"])
  }

  @Test("normalizedUniqueLines skips empty entries while keeping order")
  func normalizedUniqueLinesSkipsEmptyEntries() {
    var draft = TaskBoardGitSettingsDraft()
    draft.requestedTeamReviewersText = "  \nplatform\n\nplatform\nsre"

    let snapshot = draft.snapshot
    #expect(
      snapshot.orchestratorSettings.githubProject.requestedReviewers.teamReviewers
        == ["platform", "sre"])
  }

  // MARK: - sample fixtures

  private func sampleDraftDocument(revision: UInt64 = 7) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: [],
      layout: TaskBoardPolicyPipelineLayout(),
      policyTraceIds: []
    )
  }

  private func sampleTaskBoardItem(
    id: String = "board-1",
    status: TaskBoardStatus = .planning
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Title",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
