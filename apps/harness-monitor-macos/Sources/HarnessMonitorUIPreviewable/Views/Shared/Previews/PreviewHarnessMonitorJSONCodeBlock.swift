import HarnessMonitorKit
import SwiftUI

#Preview("JSON code block - card") {
  HarnessMonitorJSONCodeBlock(
    rawJSON: """
      {
        "summary": "Agent has not acknowledged a critical signal.",
        "routing": {
          "sessionID": "sess-1",
          "agentID": "agent-7",
          "taskID": "task-3"
        },
        "actions": [
          {
            "id": "send-check-in",
            "kind": "nudge",
            "payloadJSON": "{\\"agentID\\":\\"agent-7\\",\\"input\\":\\"Quick check-in\\"}"
          },
          {
            "id": "close-session",
            "kind": "custom",
            "payloadJSON": "{\\"mode\\":\\"closeSession\\",\\"sessionID\\":\\"sess-1\\"}"
          }
        ]
      }
      """
  )
  .padding()
  .frame(width: 520)
}

#Preview("JSON code block - plain wrapped") {
  HarnessMonitorJSONCodeBlock(
    rawJSON: """
      {
        "id": "idle-session.nudge.gemini-20260506193040829413000",
        "kind": "nudge",
        "payloadJSON": "{\\"agentID\\":\\"gemini-1\\",\\"input\\":\\"Quick check-in from supervisor.\\"}",
        "title": "Send check-in nudge"
      }
      """,
    chrome: .plain,
    wrapLongLines: true
  )
  .padding()
  .frame(width: 520)
}

#Preview("JSON code block - invalid") {
  HarnessMonitorJSONCodeBlock(
    rawJSON: #"{"id":"send-check-in","payload":{"agentID":"agent-7","input":"unterminated"}"#
  )
  .padding()
  .frame(width: 520)
}

#Preview("JSON code block - JSONValue") {
  HarnessMonitorJSONCodeBlock(
    jsonValue: .object([
      "metadata": .object([
        "path": .string("/tmp/logs/latest.log"),
        "delivered": .bool(true),
        "attempts": .number(2),
      ]),
      "summary": .string("Signal metadata"),
    ])
  )
  .padding()
  .frame(width: 520)
}
