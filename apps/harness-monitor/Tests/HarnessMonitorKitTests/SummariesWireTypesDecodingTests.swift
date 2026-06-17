import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the daemon health/readiness cluster generated
/// from src/daemon/protocol/summaries.rs. These are the first bottom-up slice of
/// that 51-type mega-file, surfaced via the generator's allow-list
/// (SUMMARIES_EMIT_ONLY) so the foundation-entangled session/observe/timeline
/// types stay out. The *Wire types own the daemon snake_case shape (explicit
/// CodingKeys, plain decoder); this pins the health decode incl. the
/// wire_version serde default, plus log-level and control. Rerouting the
/// production decode to these is a follow-up.
@Suite("Summaries wire types decoding")
struct SummariesWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("health response decodes snake_case keys and the wire_version default")
  func decodesHealth() throws {
    // wire_version is omitted, so it resolves default_wire_version (1).
    let json = #"""
    {"status":"ok","version":"1.2.3","pid":4242,"endpoint":"127.0.0.1:9999","started_at":"2026-06-17T00:00:00Z","log_level":"info","project_count":3,"worktree_count":5,"session_count":2}
    """#
    let health = try decoder.decode(HealthResponseWire.self, from: Data(json.utf8))

    #expect(health.status == "ok")
    #expect(health.version == "1.2.3")
    #expect(health.pid == 4242)
    #expect(health.startedAt == "2026-06-17T00:00:00Z")
    #expect(health.logLevel == "info")
    #expect(health.projectCount == 3)
    #expect(health.worktreeCount == 5)
    #expect(health.sessionCount == 2)
    #expect(health.wireVersion == 1)
  }

  @Test("log-level and control responses decode their snake_case keys")
  func decodesLogLevelAndControl() throws {
    let level = try decoder.decode(
      LogLevelResponseWire.self,
      from: Data(#"{"level":"debug","filter":"harness=debug"}"#.utf8)
    )
    #expect(level.level == "debug")
    #expect(level.filter == "harness=debug")

    let control = try decoder.decode(
      DaemonControlResponseWire.self,
      from: Data(#"{"status":"stopping"}"#.utf8)
    )
    #expect(control.status == "stopping")
  }
}
