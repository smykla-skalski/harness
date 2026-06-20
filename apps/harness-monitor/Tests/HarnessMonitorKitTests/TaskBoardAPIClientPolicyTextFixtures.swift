@testable import HarnessMonitorKit

let samplePolicyPipelineText =
  """
  {
    "schema_version": 2,
    "revision": 7,
    "mode": "draft",
    "nodes": [
      {
        "id": "node-intake",
        "label": "Ready for dispatch",
        "kind": { "kind": "action_gate", "actions": ["spawn_agent"] },
        "input_ports": ["in"],
        "output_ports": ["default"],
        "group_id": "group-dispatch"
      },
      {
        "id": "node-allow",
        "label": "Allow spawn",
        "kind": {
          "kind": "supervisor_rule",
          "decision": "allow",
          "reason_codes": ["default_allow"]
        },
        "input_ports": ["in"],
        "group_id": "group-dispatch"
      }
    ],
    "edges": [
      {
        "id": "edge-intake-allow",
        "from_node": "node-intake",
        "from_port": "default",
        "to_node": "node-allow",
        "to_port": "in",
        "condition": { "condition": "always" }
      }
    ],
    "groups": [
      {
        "id": "group-dispatch",
        "label": "Dispatch",
        "node_ids": ["node-intake", "node-allow"]
      }
    ],
    "layout": {
      "nodes": [
        { "node_id": "node-intake", "x": 20, "y": 40 },
        { "node_id": "node-allow", "x": 280, "y": 40 }
      ]
    },
    "policy_trace_ids": ["trace-policy-1"]
  }
  """

let samplePolicyDecisionText =
  """
  {
    "action": "spawn_agent",
    "decision": {
      "decision": "allow",
      "reason_code": "default_allow",
      "policy_version": "task-board-policy-v2:rev-7"
    },
    "policy_trace_ids": ["trace-policy-1"]
  }
  """

let samplePolicySaveDraftText =
  """
  {
    "document": \(samplePolicyPipelineText),
    "validation": { "issues": [] }
  }
  """

let samplePolicySimulationText =
  """
  {
    "revision": 7,
    "trace_id": "trace-policy-1",
    "simulated_at": "2026-05-14T11:00:05Z",
    "succeeded": true,
    "validation": {},
    "decisions": [\(samplePolicyDecisionText)],
    "policy_trace_ids": ["trace-policy-1"],
    "has_runtime_boundaries": false
  }
  """

let samplePolicyPromotionText =
  """
  {
    "document": {
      "schema_version": 2,
      "revision": 7,
      "mode": "enforced",
      "nodes": [],
      "edges": [],
      "groups": [],
      "layout": { "nodes": [] },
      "policy_trace_ids": ["trace-policy-2"]
    },
    "trace_id": "trace-policy-2"
  }
  """

let samplePolicyAuditText =
  """
  {
    "active_revision": 7,
    "mode": "draft",
    "latest_trace_id": "trace-policy-1",
    "latest_simulation": \(samplePolicySimulationText),
    "validation": { "issues": [] }
  }
  """

let samplePolicyReplayText =
  """
  {
    "sample_size": 2,
    "changed_count": 1,
    "decisions": [
      {
        "id": "policy-decision-1",
        "recorded_at": "2026-06-20T10:00:00Z",
        "action": "merge_pr",
        "historical_decision": {
          "decision": "allow",
          "reason_code": "auto_merge_allowed",
          "policy_version": "task-board-policy-v1"
        },
        "draft_decision": {
          "decision": "deny",
          "reason_code": "checks_not_green",
          "policy_version": "task-board-policy-v1"
        },
        "visited_node_ids": ["node-merge"],
        "changed": true,
        "insufficient_evidence": false
      }
    ]
  }
  """

let samplePolicyCanvasWorkspaceText =
  """
  {
    "schema_version": 1,
    "active_canvas_id": "canvas-primary",
    "canvases": [
      {
        "canvas_id": "canvas-primary",
        "title": "Primary canvas",
        "revision": 7,
        "mode": "draft",
        "node_count": 3,
        "edge_count": 1,
        "group_count": 1,
        "latest_simulation_trace_id": "trace-policy-1",
        "latest_simulation_succeeded": true,
        "latest_simulation_at": "2026-05-14T11:00:05Z",
        "updated_at": "2026-05-14T11:00:05Z"
      },
      {
        "canvas_id": "canvas-secondary",
        "title": "Secondary policy",
        "revision": 4,
        "mode": "draft",
        "node_count": 2,
        "edge_count": 0,
        "group_count": 0,
        "updated_at": "2026-05-14T11:10:05Z"
      }
    ]
  }
  """

let samplePolicyCanvasWorkspaceCreatedText =
  """
  {
    "schema_version": 1,
    "active_canvas_id": "canvas-experiment",
    "canvases": [
      {
        "canvas_id": "canvas-primary",
        "title": "Primary canvas",
        "revision": 7,
        "mode": "draft",
        "node_count": 3,
        "edge_count": 1,
        "group_count": 1,
        "latest_simulation_trace_id": "trace-policy-1",
        "latest_simulation_succeeded": true,
        "latest_simulation_at": "2026-05-14T11:00:05Z",
        "updated_at": "2026-05-14T11:00:05Z"
      },
      {
        "canvas_id": "canvas-experiment",
        "title": "Experiment A",
        "revision": 1,
        "mode": "draft",
        "node_count": 1,
        "edge_count": 0,
        "group_count": 0,
        "updated_at": "2026-05-14T11:15:05Z"
      }
    ]
  }
  """

let samplePolicyCanvasWorkspaceDuplicateText =
  """
  {
    "schema_version": 1,
    "active_canvas_id": "canvas-primary",
    "canvases": [
      {
        "canvas_id": "canvas-primary",
        "title": "Primary canvas",
        "revision": 7,
        "mode": "draft",
        "node_count": 3,
        "edge_count": 1,
        "group_count": 1,
        "latest_simulation_trace_id": "trace-policy-1",
        "latest_simulation_succeeded": true,
        "latest_simulation_at": "2026-05-14T11:00:05Z",
        "updated_at": "2026-05-14T11:00:05Z"
      },
      {
        "canvas_id": "canvas-secondary",
        "title": "Secondary policy",
        "revision": 4,
        "mode": "draft",
        "node_count": 2,
        "edge_count": 0,
        "group_count": 0,
        "updated_at": "2026-05-14T11:10:05Z"
      },
      {
        "canvas_id": "canvas-experiment-b",
        "title": "Experiment B",
        "revision": 7,
        "mode": "draft",
        "node_count": 3,
        "edge_count": 1,
        "group_count": 1,
        "updated_at": "2026-05-14T11:20:05Z"
      }
    ]
  }
  """

let samplePolicyCanvasWorkspaceRenamedText =
  """
  {
    "schema_version": 1,
    "active_canvas_id": "canvas-primary",
    "canvases": [
      {
        "canvas_id": "canvas-primary",
        "title": "Default",
        "revision": 7,
        "mode": "draft",
        "node_count": 3,
        "edge_count": 1,
        "group_count": 1,
        "latest_simulation_trace_id": "trace-policy-1",
        "latest_simulation_succeeded": true,
        "latest_simulation_at": "2026-05-14T11:00:05Z",
        "updated_at": "2026-05-14T11:25:05Z"
      },
      {
        "canvas_id": "canvas-secondary",
        "title": "Secondary policy",
        "revision": 4,
        "mode": "draft",
        "node_count": 2,
        "edge_count": 0,
        "group_count": 0,
        "updated_at": "2026-05-14T11:10:05Z"
      }
    ]
  }
  """

let samplePolicyCanvasWorkspaceActivatedText =
  """
  {
    "schema_version": 1,
    "active_canvas_id": "canvas-experiment",
    "canvases": [
      {
        "canvas_id": "canvas-primary",
        "title": "Primary canvas",
        "revision": 7,
        "mode": "draft",
        "node_count": 3,
        "edge_count": 1,
        "group_count": 1,
        "latest_simulation_trace_id": "trace-policy-1",
        "latest_simulation_succeeded": true,
        "latest_simulation_at": "2026-05-14T11:00:05Z",
        "updated_at": "2026-05-14T11:00:05Z"
      },
      {
        "canvas_id": "canvas-experiment",
        "title": "Experiment A",
        "revision": 1,
        "mode": "draft",
        "node_count": 1,
        "edge_count": 0,
        "group_count": 0,
        "updated_at": "2026-05-14T11:15:05Z"
      }
    ]
  }
  """

let samplePolicyCanvasWorkspaceDeletedText =
  """
  {
    "schema_version": 1,
    "active_canvas_id": "canvas-experiment",
    "canvases": [
      {
        "canvas_id": "canvas-primary",
        "title": "Primary canvas",
        "revision": 7,
        "mode": "draft",
        "node_count": 3,
        "edge_count": 1,
        "group_count": 1,
        "latest_simulation_trace_id": "trace-policy-1",
        "latest_simulation_succeeded": true,
        "latest_simulation_at": "2026-05-14T11:00:05Z",
        "updated_at": "2026-05-14T11:00:05Z"
      },
      {
        "canvas_id": "canvas-experiment",
        "title": "Experiment A",
        "revision": 1,
        "mode": "draft",
        "node_count": 1,
        "edge_count": 0,
        "group_count": 0,
        "updated_at": "2026-05-14T11:15:05Z"
      }
    ]
  }
  """
