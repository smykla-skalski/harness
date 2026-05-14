@testable import HarnessMonitorKit

let sampleTaskBoardItemJSON: [String: JSONValue] = [
  "schema_version": .number(1),
  "id": .string("board-1"),
  "title": .string("Board item"),
  "body": .string("Body"),
  "status": .string("todo"),
  "priority": .string("high"),
  "tags": .array([]),
  "project_id": .string("harness"),
  "agent_mode": .string("interactive"),
  "external_refs": .array([]),
  "planning": .object([:]),
  "session_id": .string("sess-1"),
  "work_item_id": .string("task-1"),
  "usage": .object([:]),
  "created_at": .string("2026-05-14T10:00:00Z"),
  "updated_at": .string("2026-05-14T10:01:00Z"),
  "deleted_at": .null,
]

let sampleTaskBoardDispatchSummaryJSON: [String: JSONValue] = [
  "plans": .array([
    .object([
      "board_item_id": .string("board-1"),
      "readiness": .object([
        "state": .string("ready"),
        "reason": .null,
      ]),
      "session": .object([
        "kind": .string("existing"),
        "session_id": .string("sess-1"),
        "title": .null,
        "context": .null,
        "project_id": .string("project-1"),
      ]),
      "task": .object([
        "title": .string("Board item"),
        "context": .string("Body"),
        "severity": .string("high"),
        "suggested_fix": .string("Use the approved plan."),
        "source": .string("manual"),
        "tags": .array([.string("automation")]),
        "external_refs": .array([]),
      ]),
      "worker": .object(["mode": .string("interactive")]),
      "reviewer": .object([
        "phase": .string("review"),
        "suggested_persona": .string("reviewer"),
        "required_consensus": .number(1),
      ]),
      "evaluator": .object([
        "phase": .string("evaluate"),
        "mode": .string("evaluate"),
      ]),
      "policy": .object([
        "decision": .string("allow"),
        "reason_code": .string("default_allow"),
        "policy_version": .string("task-board-policy-v1"),
      ]),
    ])
  ]),
  "applied": .array([
    .object([
      "board_item_id": .string("board-1"),
      "session_id": .string("sess-1"),
      "work_item_id": .string("task-1"),
      "item": .object(sampleTaskBoardItemJSON),
    ])
  ]),
]

let sampleTaskBoardItemJSONString =
  """
  {
    "schema_version": 1,
    "id": "board-1",
    "title": "Board item",
    "body": "Body",
    "status": "todo",
    "priority": "high",
    "tags": [],
    "project_id": "harness",
    "agent_mode": "interactive",
    "external_refs": [],
    "planning": {},
    "session_id": "sess-1",
    "work_item_id": "task-1",
    "usage": {},
    "created_at": "2026-05-14T10:00:00Z",
    "updated_at": "2026-05-14T10:01:00Z",
    "deleted_at": null
  }
  """

let sampleTaskBoardDispatchSummaryJSONString =
  """
  {
    "plans": [
      {
        "board_item_id": "board-1",
        "readiness": { "state": "ready", "reason": null },
        "session": {
          "kind": "existing",
          "session_id": "sess-1",
          "title": null,
          "context": null,
          "project_id": "project-1"
        },
        "task": {
          "title": "Board item",
          "context": "Body",
          "severity": "high",
          "suggested_fix": "Use the approved plan.",
          "source": "manual",
          "tags": ["automation"],
          "external_refs": []
        },
        "worker": { "mode": "interactive" },
        "reviewer": {
          "phase": "review",
          "suggested_persona": "reviewer",
          "required_consensus": 1
        },
        "evaluator": { "phase": "evaluate", "mode": "evaluate" },
        "policy": {
          "decision": "allow",
          "reason_code": "default_allow",
          "policy_version": "task-board-policy-v1"
        }
      }
    ],
    "applied": [
      {
        "board_item_id": "board-1",
        "session_id": "sess-1",
        "work_item_id": "task-1",
        "item": \(sampleTaskBoardItemJSONString)
      }
    ]
  }
  """
