import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the task-board foundation enums, generated from
/// src/task_board/types.rs and adopted in place (the hand enums were deleted, the
/// generated open/closed enums replace them, and the app-only `title` moved to an
/// extension). TaskBoardStatus/TaskBoardAgentMode are open (unknown-tolerant) and
/// TaskBoardPriority is closed. These prove the snake_case wire values decode to the
/// exact cases the app already used, unknown values survive, and the title extension
/// still resolves.
@Suite("Task board foundation enums")
struct TaskBoardEnumsWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder
  private let encoder = JSONEncoder()

  @Test("decodes task board status snake_case values")
  func decodesStatus() throws {
    #expect(try decode(TaskBoardStatus.self, "in_review") == .inReview)
    #expect(try decode(TaskBoardStatus.self, "needs_you") == .needsYou)
    #expect(try decode(TaskBoardStatus.self, "plan_review") == .planReview)
    #expect(try decode(TaskBoardStatus.self, "todo") == .todo)
    #expect(try decode(TaskBoardStatus.self, "frobnicate") == .unknown("frobnicate"))
  }

  @Test("encodes status back to its snake_case wire value")
  func encodesStatus() throws {
    #expect(try wireString(TaskBoardStatus.inReview) == "in_review")
    #expect(try wireString(TaskBoardStatus.needsYou) == "needs_you")
  }

  @Test("status title extension survives adoption")
  func statusTitle() {
    #expect(TaskBoardStatus.inReview.title == "In Review")
    #expect(TaskBoardStatus.todo.title == "Ready")
    #expect(TaskBoardStatus.unknown("custom").title == "custom")
  }

  @Test("decodes agent mode including the unknown fallback")
  func decodesAgentMode() throws {
    #expect(try decode(TaskBoardAgentMode.self, "headless") == .headless)
    #expect(try decode(TaskBoardAgentMode.self, "evaluate") == .evaluate)
    #expect(try decode(TaskBoardAgentMode.self, "swarm") == .unknown("swarm"))
    #expect(TaskBoardAgentMode.interactive.title == "Interactive")
  }

  @Test("decodes the closed priority enum")
  func decodesPriority() throws {
    #expect(try decode(TaskBoardPriority.self, "critical") == .critical)
    #expect(try decode(TaskBoardPriority.self, "low") == .low)
    #expect(TaskBoardPriority.critical.title == "Critical")
  }

  private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
    try decoder.decode(T.self, from: Data("\"\(raw)\"".utf8))
  }

  private func wireString(_ value: some Encodable) throws -> String {
    (String(bytes: try encoder.encode(value), encoding: .utf8) ?? "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }
}
