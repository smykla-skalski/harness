import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the observe issue classification enums, generated from
/// src/observe/types/{classification,issue_code}.rs. They own the daemon's
/// snake_case wire strings; ObserverIssueSummary decodes these as String today,
/// so this pins the typed form ahead of the summaries migration. They are open
/// enums (TaskBoardOpenEnum) - an unrecognized value decodes to .unknown rather
/// than throwing, matching the String "accepts anything" behaviour they replace
/// and staying forward-compatible as the harness taxonomy grows.
@Suite("Observe classification wire enums")
struct ObserveWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes IssueSeverity from its snake_case wire strings")
  func decodesSeverity() throws {
    #expect(try decodeEnum(IssueSeverity.self, "low") == .low)
    #expect(try decodeEnum(IssueSeverity.self, "medium") == .medium)
    #expect(try decodeEnum(IssueSeverity.self, "critical") == .critical)
    #expect(try decodeEnum(IssueSeverity.self, "catastrophic") == .unknown("catastrophic"))
  }

  @Test("decodes IssueCategory including multi-word snake keys")
  func decodesCategory() throws {
    #expect(try decodeEnum(IssueCategory.self, "hook_failure") == .hookFailure)
    #expect(try decodeEnum(IssueCategory.self, "agent_coordination") == .agentCoordination)
    #expect(try decodeEnum(IssueCategory.self, "user_frustration") == .userFrustration)
    #expect(try decodeEnum(IssueCategory.self, "from_the_future") == .unknown("from_the_future"))
  }

  @Test("decodes FixSafety from its snake_case wire strings")
  func decodesFixSafety() throws {
    #expect(try decodeEnum(FixSafety.self, "auto_fix_safe") == .autoFixSafe)
    #expect(try decodeEnum(FixSafety.self, "triage_required") == .triageRequired)
    #expect(try decodeEnum(FixSafety.self, "advisory_only") == .advisoryOnly)
  }

  @Test("decodes IssueCode and round-trips through its rawValue")
  func decodesIssueCode() throws {
    #expect(try decodeEnum(IssueCode.self, "hook_denied_tool_call") == .hookDeniedToolCall)
    #expect(try decodeEnum(IssueCode.self, "non_zero_exit_code") == .nonZeroExitCode)
    #expect(IssueCode.crossAgentFileConflict.rawValue == "cross_agent_file_conflict")
    #expect(try decodeEnum(IssueCode.self, "future_code") == .unknown("future_code"))
  }

  @Test("encodes back to the daemon wire string")
  func encodesToWireString() throws {
    let data = try JSONEncoder().encode(FixSafety.autoFixGuarded)
    #expect(String(bytes: data, encoding: .utf8) == "\"auto_fix_guarded\"")
  }

  private func decodeEnum<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    try decoder.decode(T.self, from: Data("\"\(value)\"".utf8))
  }
}
