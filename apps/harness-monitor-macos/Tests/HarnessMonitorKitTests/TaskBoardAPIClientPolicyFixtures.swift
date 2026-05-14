@testable import HarnessMonitorKit

let samplePolicyPipelineJSON: [String: JSONValue] = [
  "schema_version": .number(2),
  "revision": .number(7),
  "mode": .string("draft"),
  "nodes": .array([
    .object([
      "id": .string("node-intake"),
      "label": .string("Ready for dispatch"),
      "kind": .object([
        "kind": .string("action_gate"),
        "actions": .array([.string("spawn_agent")]),
      ]),
      "input_ports": .array([.string("in")]),
      "output_ports": .array([.string("default")]),
      "group_id": .string("group-dispatch"),
    ]),
    .object([
      "id": .string("node-allow"),
      "label": .string("Allow spawn"),
      "kind": .object([
        "kind": .string("supervisor_rule"),
        "decision": .string("allow"),
        "reason_codes": .array([.string("default_allow")]),
      ]),
      "input_ports": .array([.string("in")]),
      "group_id": .string("group-dispatch"),
    ]),
  ]),
  "edges": .array([
    .object([
      "id": .string("edge-intake-allow"),
      "from_node": .string("node-intake"),
      "from_port": .string("default"),
      "to_node": .string("node-allow"),
      "to_port": .string("in"),
      "condition": .object(["condition": .string("always")]),
    ])
  ]),
  "groups": .array([
    .object([
      "id": .string("group-dispatch"),
      "label": .string("Dispatch"),
      "node_ids": .array([.string("node-intake"), .string("node-allow")]),
    ])
  ]),
  "layout": .object([
    "nodes": .array([
      .object(["node_id": .string("node-intake"), "x": .number(20), "y": .number(40)]),
      .object(["node_id": .string("node-allow"), "x": .number(280), "y": .number(40)]),
    ])
  ]),
  "policy_trace_ids": .array([.string("trace-policy-1")]),
]

let samplePolicyDecisionJSON: [String: JSONValue] = [
  "action": .string("spawn_agent"),
  "decision": .object([
    "decision": .string("allow"),
    "reason_code": .string("default_allow"),
    "policy_version": .string("task-board-policy-v2:rev-7"),
  ]),
  "visited_node_ids": .array([.string("node-intake"), .string("node-allow")]),
  "policy_trace_ids": .array([.string("trace-policy-1")]),
]

let samplePolicySaveDraftJSON: [String: JSONValue] = [
  "document": .object(samplePolicyPipelineJSON),
  "validation": .object(["issues": .array([])]),
]

let samplePolicySimulationJSON: [String: JSONValue] = [
  "revision": .number(7),
  "trace_id": .string("trace-policy-1"),
  "simulated_at": .string("2026-05-14T11:00:05Z"),
  "succeeded": .bool(true),
  "validation": .object(["issues": .array([])]),
  "decisions": .array([.object(samplePolicyDecisionJSON)]),
  "policy_trace_ids": .array([.string("trace-policy-1")]),
]

let samplePolicyPromotionJSON: [String: JSONValue] = [
  "document": .object(
    samplePolicyPipelineJSON.merging(["mode": .string("enforced")]) { _, new in new }
  ),
  "trace_id": .string("trace-policy-2"),
]

let samplePolicyAuditJSON: [String: JSONValue] = [
  "active_revision": .number(7),
  "mode": .string("draft"),
  "latest_trace_id": .string("trace-policy-1"),
  "latest_simulation": .object(samplePolicySimulationJSON),
  "validation": .object(["issues": .array([])]),
]

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
    "visited_node_ids": ["node-intake", "node-allow"],
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
    "validation": { "issues": [] },
    "decisions": [\(samplePolicyDecisionText)],
    "policy_trace_ids": ["trace-policy-1"]
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
