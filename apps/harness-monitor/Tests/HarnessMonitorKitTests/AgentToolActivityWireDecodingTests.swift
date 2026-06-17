import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the agent tool-activity cluster, generated from
/// src/daemon/protocol/summaries.rs and src/hooks/protocol/payloads.rs.
/// AgentToolActivitySummary nests in SessionDetail.agent_activity and pulls
/// AgentPendingUserPrompt -> the hooks AskUserQuestionPrompt -> AskUserQuestionOption.
/// These prove the daemon's nested snake_case payload decodes into the typed wire
/// graph through the plain decoder, including the lenient serde(default) fields. The
/// hand models rename the hooks types (AgentPendingUserPromptQuestion/Option) and the
/// pending-prompt model carries a legacy message-synthesis init, so this stays
/// generate-only until the SessionDetail reroute.
@Suite("Agent tool-activity wire graph")
struct AgentToolActivityWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes the tool-activity graph including the nested prompt options")
  func decodesToolActivityGraph() throws {
    let summary = try decoder.decode(
      AgentToolActivitySummaryWire.self, from: Data(toolActivityPayloadFixture.utf8)
    )

    #expect(summary.agentId == "agent-9")
    #expect(summary.toolInvocationCount == 42)
    #expect(summary.toolErrorCount == 2)
    #expect(summary.recentTools == ["Read", "Edit", "Bash"])

    let pending = try #require(summary.pendingUserPrompt)
    #expect(pending.toolName == "AskUserQuestion")

    let question = try #require(pending.questions.first)
    #expect(question.question == "Which approach?")
    #expect(question.header == "Approach")
    #expect(question.multiSelect == false)
    #expect(question.options.count == 2)
    #expect(question.options[0].label == "Option A")
    #expect(question.options[0].description == "first")
    #expect(question.options[1].label == "Option B")
    #expect(question.options[1].description == "")
  }

  @Test("decodes a summary with no pending user prompt")
  func decodesWithoutPendingPrompt() throws {
    let summary = try decoder.decode(
      AgentToolActivitySummaryWire.self, from: Data(toolActivityNoPromptFixture.utf8)
    )
    #expect(summary.pendingUserPrompt == nil)
    #expect(summary.recentTools.isEmpty)
    #expect(summary.toolInvocationCount == 0)
  }

  @Test("defaults absent AskUserQuestionPromptWire fields")
  func decodesAskQuestionDefaults() throws {
    let prompt = try decoder.decode(
      AskUserQuestionPromptWire.self, from: Data(bareQuestionFixture.utf8)
    )
    #expect(prompt.question == "Proceed?")
    #expect(prompt.header == nil)
    #expect(prompt.options.isEmpty)
    #expect(prompt.multiSelect == false)
  }
}

private let toolActivityPayloadFixture = """
  {
    "agent_id": "agent-9",
    "runtime": "claude",
    "tool_invocation_count": 42,
    "tool_result_count": 40,
    "tool_error_count": 2,
    "latest_tool_name": "Bash",
    "latest_event_at": "2026-06-17T10:00:00Z",
    "recent_tools": ["Read", "Edit", "Bash"],
    "pending_user_prompt": {
      "tool_name": "AskUserQuestion",
      "waiting_since": "2026-06-17T09:59:00Z",
      "questions": [
        {
          "question": "Which approach?",
          "header": "Approach",
          "options": [
            { "label": "Option A", "description": "first" },
            { "label": "Option B" }
          ],
          "multi_select": false
        }
      ],
      "message": "Which approach?"
    }
  }
  """

private let toolActivityNoPromptFixture = """
  {
    "agent_id": "agent-9",
    "runtime": "claude",
    "tool_invocation_count": 0,
    "tool_result_count": 0,
    "tool_error_count": 0,
    "recent_tools": []
  }
  """

private let bareQuestionFixture = """
  {
    "question": "Proceed?"
  }
  """
