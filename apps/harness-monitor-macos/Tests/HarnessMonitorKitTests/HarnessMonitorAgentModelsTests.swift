import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor agent models v10")
struct HarnessMonitorAgentModelsTests {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  init() {
    decoder.keyDecodingStrategy = .convertFromSnakeCase
  }

  @Test("AgentStatus decodes awaiting_review snake case")
  func agentStatusDecodesAwaitingReview() throws {
    let data = Data("\"awaiting_review\"".utf8)
    let status = try decoder.decode(AgentStatus.self, from: data)
    #expect(status == .awaitingReview)
  }

  @Test("AgentStatus decodes idle")
  func agentStatusDecodesIdle() throws {
    let data = Data("\"idle\"".utf8)
    let status = try decoder.decode(AgentStatus.self, from: data)
    #expect(status == .idle)
  }

  @Test("AgentStatus encodes idle snake case")
  func agentStatusEncodesIdle() throws {
    let data = try encoder.encode(AgentStatus.awaitingReview)
    let string = String(bytes: data, encoding: .utf8)
    #expect(string == "\"awaiting_review\"")
  }

  @Test("AgentStatus sort priority reorders awaiting review")
  func agentStatusSortPriorityReorder() {
    #expect(AgentStatus.active.sortPriority == 0)
    #expect(AgentStatus.awaitingReview.sortPriority == 1)
    #expect(AgentStatus.idle.sortPriority == 2)
    #expect(AgentStatus.disconnected.sortPriority == 3)
    #expect(AgentStatus.removed.sortPriority == 4)
  }

  @Test("AgentStatus decodes legacy camelCase awaitingReview")
  func agentStatusLegacyCamelCaseFallback() throws {
    let data = Data("\"awaitingReview\"".utf8)
    let status = try decoder.decode(AgentStatus.self, from: data)
    #expect(status == .awaitingReview)
  }

  @Test("AgentRegistration.isAutoSpawned true when capability present")
  func agentRegistrationIsAutoSpawnedFromCapabilities() {
    let capabilities = RuntimeCapabilities(
      runtime: "claude",
      supportsNativeTranscript: true,
      supportsSignalDelivery: true,
      supportsContextInjection: true,
      typicalSignalLatencySeconds: 1,
      hookPoints: []
    )
    let auto = AgentRegistration(
      agentId: "rev-1",
      name: "Reviewer",
      runtime: "claude",
      role: .reviewer,
      capabilities: [AgentRegistration.autoSpawnedCapability],
      joinedAt: "2026-04-24T00:00:00Z",
      updatedAt: "2026-04-24T00:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
    let manual = AgentRegistration(
      agentId: "rev-2",
      name: "Reviewer",
      runtime: "claude",
      role: .reviewer,
      capabilities: ["general"],
      joinedAt: "2026-04-24T00:00:00Z",
      updatedAt: "2026-04-24T00:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
    #expect(auto.isAutoSpawned)
    #expect(!manual.isAutoSpawned)
  }

  @Test("AgentPendingUserPrompt decodes canonical ask-user questions")
  func agentPendingUserPromptDecodesCanonicalQuestions() throws {
    let data = Data(
      """
      {
        "tool_name": "AskUserQuestion",
        "waiting_since": "2026-04-28T08:00:01Z",
        "questions": [{
          "question": "Approve the file write?",
          "header": "Approval",
          "options": [
            { "label": "Allow", "description": "Proceed with the write" },
            { "label": "Deny", "description": "Stop before writing" }
          ],
          "multi_select": false
        }]
      }
      """.utf8
    )

    let prompt = try decoder.decode(AgentPendingUserPrompt.self, from: data)

    #expect(prompt.toolName == "AskUserQuestion")
    #expect(prompt.waitingSince == "2026-04-28T08:00:01Z")
    #expect(prompt.primaryQuestion?.header == "Approval")
    #expect(prompt.primaryQuestion?.options.map(\.label) == ["Allow", "Deny"])
  }
}
