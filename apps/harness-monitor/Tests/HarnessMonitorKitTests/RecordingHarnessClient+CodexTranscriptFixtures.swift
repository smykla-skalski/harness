import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  static func codexTranscriptEntries(for run: CodexRunSnapshot) -> [TimelineEntry] {
    var entries = [
      codexTranscriptEntry(
        CodexTranscriptEntryFixture(
          run: run,
          suffix: "prompt",
          recordedAt: run.createdAt,
          kind: "user_prompt",
          summary: run.prompt,
          event: .object([
            "type": .string("user_prompt"),
            "content": .string(run.prompt),
          ])
        )
      )
    ]
    if let finalMessage = run.finalMessage {
      entries.append(
        codexTranscriptEntry(
          CodexTranscriptEntryFixture(
            run: run,
            suffix: "final",
            recordedAt: run.updatedAt,
            kind: "assistant_text",
            summary: finalMessage,
            event: .object([
              "type": .string("assistant_text"),
              "content": .string(finalMessage),
              "final": .bool(true),
            ])
          )
        )
      )
    }
    return entries
  }

  private struct CodexTranscriptEntryFixture {
    let run: CodexRunSnapshot
    let suffix: String
    let recordedAt: String
    let kind: String
    let summary: String
    let event: JSONValue
  }

  private static func codexTranscriptEntry(
    _ fixture: CodexTranscriptEntryFixture
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: "codex-\(fixture.run.runId)-\(fixture.suffix)",
      recordedAt: fixture.recordedAt,
      kind: fixture.kind,
      sessionId: fixture.run.sessionId,
      agentId: fixture.run.sessionAgentId,
      taskId: nil,
      summary: fixture.summary,
      payload: .object([
        "runtime": .string("codex"),
        "event": fixture.event,
        "codex_timeline_identity": .object([
          "run_id": .string(fixture.run.runId),
          "agent_id": optionalStringValue(fixture.run.sessionAgentId),
          "agent_display_name": optionalStringValue(fixture.run.displayName),
          "thread_id": optionalStringValue(fixture.run.threadId),
          "turn_id": optionalStringValue(fixture.run.turnId),
        ]),
      ])
    )
  }

  private static func optionalStringValue(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }
}
