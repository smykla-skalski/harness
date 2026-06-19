import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the git signing verify outcome (git/signing/verify). Generated from
/// daemon/protocol/task_board.rs as an internally-tagged enum on "outcome"; the signed variant pins
/// the snake_case signature_kind field decoding through the plain PolicyWireCoding.decoder, the case
/// that the convertFromSnakeCase fallback used to paper over.
@Suite("Task board git signing verify wire decoding")
struct TaskBoardGitSigningVerifyWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  private func decodeOutcome(_ json: String) throws -> TaskBoardGitSigningVerifyResponse {
    let data = try #require(json.data(using: .utf8))
    let wire = try decoder.decode(TaskBoardGitSigningVerifyResponseWire.self, from: data)
    return TaskBoardGitSigningVerifyResponse(wire: wire)
  }

  @Test("signed maps the mode and the snake_case signature_kind field")
  func signedOutcome() throws {
    let outcome = try decodeOutcome(
      #"{"outcome": "signed", "mode": "ssh", "signature_kind": "openssh"}"#)
    #expect(outcome == .signed(mode: "ssh", signatureKind: "openssh"))
  }

  @Test("skipped maps the unit variant")
  func skippedOutcome() throws {
    let outcome = try decodeOutcome(#"{"outcome": "skipped"}"#)
    #expect(outcome == .skipped)
  }

  @Test("failed maps the message field")
  func failedOutcome() throws {
    let outcome = try decodeOutcome(#"{"outcome": "failed", "message": "no key configured"}"#)
    #expect(outcome == .failed(message: "no key configured"))
  }
}
