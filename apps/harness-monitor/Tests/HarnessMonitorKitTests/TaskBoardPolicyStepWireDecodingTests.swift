import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

@Suite("Task-board policy step wire decoding")
struct TaskBoardPolicyStepWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("maps fail-closed and kill-switch workspace state")
  func mapsSpawnGuardWorkspaceState() throws {
    let wire = try decoder.decode(
      PolicyCanvasWorkspaceResponseWire.self,
      from: Data(policyWorkspaceFixture.utf8)
    )
    let workspace = PolicyCanvasWorkspace(wire: wire)

    #expect(workspace.spawnRequiresLivePolicy)
    #expect(workspace.spawnKillSwitch)
  }

  @Test("decodes enriched policy input and approval state")
  func decodesPolicyInputEnrichment() throws {
    let input = try decoder.decode(
      HarnessMonitorPolicyModels.PolicyInput.self,
      from: Data(policyInputEnrichmentFixture.utf8)
    )

    #expect(input.evaluatedAt == "2026-07-14T00:00:00Z")
    #expect(input.subject.tags == ["swift", "monitor"])
    #expect(input.subject.priority?.rawValue == "critical")
    #expect(input.subject.agentMode?.rawValue == "interactive")
    #expect(input.subject.targetProjectTypes == ["macos"])
    #expect(input.approvals.first?.nodeId == "approval-1")
    #expect(input.approvals.first?.state == .approved)
  }

  @Test("decodes pending approval grants from the route envelope")
  func decodesApprovalGrantList() throws {
    let response = try decoder.decode(
      PolicyApprovalGrantsListResponse.self,
      from: Data(policyApprovalGrantListFixture.utf8)
    )
    let grant = try #require(response.grants.first)

    #expect(grant.id == "grant-1")
    #expect(grant.boardItemId == "task-1")
    #expect(grant.action == .spawnAgent)
    #expect(grant.state == .pending)
    #expect(grant.expirySeconds == 900)
  }
}

private let policyWorkspaceFixture = """
  {
    "schema_version": 1,
    "active_canvas_id": "canvas-1",
    "spawn_requires_live_policy": true,
    "spawn_kill_switch": true
  }
  """

private let policyInputEnrichmentFixture = """
  {
    "action": "spawn_agent",
    "subject": {
      "task_board_item_id": "task-1",
      "tags": ["swift", "monitor"],
      "priority": "critical",
      "agent_mode": "interactive",
      "target_project_types": ["macos"]
    },
    "evaluated_at": "2026-07-14T00:00:00Z",
    "approvals": [{"node_id": "approval-1", "state": "approved"}]
  }
  """

private let policyApprovalGrantListFixture = """
  {
    "grants": [
      {
        "id": "grant-1",
        "board_item_id": "task-1",
        "action": "spawn_agent",
        "canvas_id": "canvas-1",
        "canvas_revision": 3,
        "node_id": "approval-1",
        "reason_code": "approval_required",
        "state": "pending",
        "expiry_seconds": 900,
        "created_at": "2026-07-14T00:00:00Z",
        "updated_at": "2026-07-14T00:00:00Z"
      }
    ]
  }
  """
