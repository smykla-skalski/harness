import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor agent models v10")
struct HarnessMonitorAgentModelsTests {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

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
}
