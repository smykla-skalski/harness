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
      {"status":"ok","version":"1.2.3","pid":4242,"endpoint":"127.0.0.1:9999",
      "started_at":"2026-06-17T00:00:00Z","log_level":"info","project_count":3,
      "worktree_count":5,"session_count":2}
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

  @Test("github diagnostics decode their nested buckets and snake_case keys")
  func decodesGitHubDiagnostics() throws {
    let json = #"""
      {"data_revision":17,
      "buckets":[{"resource":"core","remaining":4900,"limit":5000,"used":100,
      "reset_at":"2026-06-17T01:00:00Z"}],
      "cooling":[{"resource":"graphql","reason":"secondary_rate_limit","until_seconds_from_now":42}],
      "last_hour_network_requests":1200,"last_hour_graphql_points":850,"cache_hits":300,
      "cache_stale_hits":12,"cache_deferred_hits":4,"deferred_budget":1000,
      "top_operations":[{"operation":"list_pulls","network_requests":40,"graphql_points":0}]}
      """#
    let diagnostics = try decoder.decode(GitHubApiDiagnosticsWire.self, from: Data(json.utf8))

    #expect(diagnostics.dataRevision == 17)
    #expect(diagnostics.lastHourNetworkRequests == 1200)
    #expect(diagnostics.lastHourGraphqlPoints == 850)
    #expect(diagnostics.cacheStaleHits == 12)
    #expect(diagnostics.deferredBudget == 1000)

    #expect(diagnostics.buckets.count == 1)
    #expect(diagnostics.buckets[0].resource == "core")
    #expect(diagnostics.buckets[0].resetAt == "2026-06-17T01:00:00Z")

    #expect(diagnostics.cooling.count == 1)
    #expect(diagnostics.cooling[0].untilSecondsFromNow == 42)

    #expect(diagnostics.topOperations.count == 1)
    #expect(diagnostics.topOperations[0].operation == "list_pulls")
    #expect(diagnostics.topOperations[0].networkRequests == 40)
  }
}
