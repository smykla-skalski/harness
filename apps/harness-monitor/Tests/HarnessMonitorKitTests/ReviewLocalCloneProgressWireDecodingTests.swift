import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the reviews local-clone progress push payload. Generated from
/// reviews/files/local_clone_progress_event.rs as an internally-tagged enum on "kind"; the map
/// flattens it into the hand ReviewLocalCloneProgress struct (kind discriminator + per-variant
/// optional duration/message), and the operation rides the string-serialized LocalCloneOperationWire.
@Suite("Review local clone progress wire decoding")
struct ReviewLocalCloneProgressWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  private func decodeProgress(_ json: String) throws -> ReviewLocalCloneProgress {
    let data = try #require(json.data(using: .utf8))
    let wire = try decoder.decode(LocalCloneProgressEventPayloadWire.self, from: data)
    return ReviewLocalCloneProgress(wire: wire)
  }

  @Test("started maps the repo, operation and nil duration/message")
  func startedVariant() throws {
    let progress = try decodeProgress(
      #"{"kind": "started", "repo_full_name": "acme/widget", "operation": "clone"}"#
    )
    #expect(progress.kind == .started)
    #expect(progress.repoFullName == "acme/widget")
    #expect(progress.operation == .clone)
    #expect(progress.durationMillis == nil)
    #expect(progress.message == nil)
  }

  @Test("completed maps the duration and fetch operation")
  func completedVariant() throws {
    let progress = try decodeProgress(
      #"""
      {"kind": "completed", "repo_full_name": "acme/widget", "operation": "fetch",
       "duration_millis": 1234}
      """#
    )
    #expect(progress.kind == .completed)
    #expect(progress.operation == .fetch)
    #expect(progress.durationMillis == 1234)
    #expect(progress.message == nil)
  }

  @Test("failed maps the message")
  func failedVariant() throws {
    let progress = try decodeProgress(
      #"""
      {"kind": "failed", "repo_full_name": "acme/widget", "operation": "clone",
       "message": "auth failed"}
      """#
    )
    #expect(progress.kind == .failed)
    #expect(progress.message == "auth failed")
    #expect(progress.durationMillis == nil)
  }
}
