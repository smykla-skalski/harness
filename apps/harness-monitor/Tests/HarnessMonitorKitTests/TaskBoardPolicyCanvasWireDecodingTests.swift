import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the task-board policy-canvas read cluster, generated from
/// src/daemon/protocol/task_board.rs. The workspace response nests the per-canvas
/// summaries (each carrying a full pipeline document), and the export response is
/// the single-canvas document payload. These prove the daemon snake_case envelope
/// decodes through the plain decoder into the wire types and maps to the rich hand
/// models: the mode bridges by raw value, the usize counts narrow to Int, and the
/// document passes straight through the plain-decoder-safe hand type. generate-only.
@Suite("Task board policy canvas wire types")
struct TaskBoardPolicyCanvasWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a workspace response and maps to the hand model")
  func decodesWorkspaceResponse() throws {
    let wire = try decoder.decode(
      TaskBoardPolicyCanvasWorkspaceResponseWire.self,
      from: Data(canvasWorkspacePayloadFixture.utf8)
    )

    #expect(wire.schemaVersion == 3)
    #expect(wire.activeCanvasId == "canvas-1")
    #expect(wire.globalPolicyEnforcementEnabled == false)
    #expect(wire.canvases.count == 1)

    let summaryWire = try #require(wire.canvases.first)
    #expect(summaryWire.canvasId == "canvas-1")
    #expect(summaryWire.mode == .enforced)
    #expect(summaryWire.nodeCount == 2)
    #expect(summaryWire.latestSimulationSucceeded == true)
    #expect(summaryWire.document.revision == 5)

    let workspace = TaskBoardPolicyCanvasWorkspace(wire: wire)
    #expect(workspace.schemaVersion == 3)
    #expect(workspace.globalPolicyEnforcementEnabled == false)

    let summary = try #require(workspace.canvases.first)
    #expect(summary.canvasId == "canvas-1")
    #expect(summary.mode == .enforced)
    #expect(summary.nodeCount == 2)
    #expect(summary.edgeCount == 1)
    #expect(summary.groupCount == 0)
    #expect(summary.latestSimulationTraceId == "trace-9")
    #expect(summary.document?.revision == 5)
    #expect(summary.document?.mode == .draft)
  }

  @Test("defaults the enforcement flag and canvases when absent")
  func defaultsWorkspaceOptionalFields() throws {
    let wire = try decoder.decode(
      TaskBoardPolicyCanvasWorkspaceResponseWire.self,
      from: Data(#"{"schema_version": 1, "active_canvas_id": "c0"}"#.utf8)
    )
    #expect(wire.canvases.isEmpty)
    #expect(wire.globalPolicyEnforcementEnabled == true)

    let workspace = TaskBoardPolicyCanvasWorkspace(wire: wire)
    #expect(workspace.activeCanvasId == "c0")
    #expect(workspace.globalPolicyEnforcementEnabled == true)
  }

  @Test("decodes an export response and maps to the hand model")
  func decodesExportResponse() throws {
    let wire = try decoder.decode(
      TaskBoardPolicyExportResponseWire.self, from: Data(canvasExportPayloadFixture.utf8)
    )
    #expect(wire.canvasId == "canvas-7")
    #expect(wire.title == "Exported")
    #expect(wire.document.revision == 12)

    let response = TaskBoardPolicyExportResponse(wire: wire)
    #expect(response.canvasId == "canvas-7")
    #expect(response.document.mode == .dryRun)
  }
}

private let minimalDocumentFixture = """
  {
    "schema_version": 2,
    "revision": 5,
    "mode": "draft",
    "nodes": [],
    "edges": [],
    "groups": [],
    "layout": {},
    "policy_trace_ids": []
  }
  """

private let canvasWorkspacePayloadFixture = """
  {
    "schema_version": 3,
    "active_canvas_id": "canvas-1",
    "global_policy_enforcement_enabled": false,
    "canvases": [
      {
        "canvas_id": "canvas-1",
        "title": "Default",
        "revision": 5,
        "mode": "enforced",
        "document": \(minimalDocumentFixture),
        "node_count": 2,
        "edge_count": 1,
        "group_count": 0,
        "latest_simulation_trace_id": "trace-9",
        "latest_simulation_succeeded": true,
        "latest_simulation_at": "2026-06-17T10:00:00Z",
        "updated_at": "2026-06-17T10:01:00Z"
      }
    ]
  }
  """

private let canvasExportPayloadFixture = """
  {
    "canvas_id": "canvas-7",
    "title": "Exported",
    "document": {
      "schema_version": 2,
      "revision": 12,
      "mode": "dry_run",
      "nodes": [],
      "edges": [],
      "groups": [],
      "layout": {},
      "policy_trace_ids": []
    }
  }
  """
