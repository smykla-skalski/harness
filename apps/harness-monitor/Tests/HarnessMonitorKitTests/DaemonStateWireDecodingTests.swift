import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the `/v1/diagnostics` report. The daemon-state
/// wire types are generated from the Rust diagnostics/manifest/launch-agent
/// structs by examples/policy-codegen.rs, so they spell explicit snake_case
/// `CodingKeys` and decode through `PolicyWireCoding.decoder` (no key strategy).
/// The rich `DaemonDiagnosticsReport`/`DaemonManifest`/`DaemonDiagnostics` hand
/// models keep their legacy decode paths and Foundation-backed defaulting;
/// `DaemonStatusModels+Wire.swift` folds wire -> model at the transport boundary.
/// This feeds the daemon's byte-for-byte payload through that pairing and asserts
/// every field survives - including that the unmodeled `acp_runtime_probe` and
/// `manifest.ownership` keys are tolerated and dropped, matching the prior
/// convert decode that simply ignored them.
@Suite("Daemon state wire decoding")
struct DaemonStateWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  /// Byte-for-byte daemon payload: snake_case wire keys, a nested manifest with
  /// host_bridge capabilities + binary_stamp, a github_api sub-report, a workspace
  /// with a last_event, recent_events, and the two keys the app does not model
  /// (acp_runtime_probe, manifest.ownership).
  private let daemonPayload = #"""
    {
      "health": {
        "status": "ok",
        "version": "1.4.2",
        "pid": 9876,
        "endpoint": "http://127.0.0.1:842",
        "started_at": "2026-06-15T10:00:00Z",
        "log_level": "info",
        "project_count": 3,
        "worktree_count": 5,
        "session_count": 2,
        "wire_version": 2
      },
      "manifest": {
        "version": "1.4.2",
        "pid": 1234,
        "endpoint": "http://127.0.0.1:842",
        "started_at": "2026-06-15T09:59:00Z",
        "token_path": "/Users/x/.harness/token",
        "sandboxed": true,
        "host_bridge": {
          "running": true,
          "socket_path": "/tmp/harness-bridge.sock",
          "capabilities": {
            "codex": {
              "enabled": true,
              "healthy": true,
              "transport": "websocket",
              "endpoint": "ws://127.0.0.1:9000",
              "metadata": {"region": "local"}
            }
          }
        },
        "revision": 7,
        "updated_at": "2026-06-15T10:01:00Z",
        "binary_stamp": {
          "helper_path": "/Applications/Harness.app/helper",
          "device_identifier": 999,
          "inode": 4242,
          "file_size": 1048576,
          "modification_time_interval_since_1970": 1750000000.5
        },
        "ownership": "external"
      },
      "launch_agent": {
        "installed": true,
        "loaded": true,
        "label": "com.harness.daemon",
        "path": "/Users/x/Library/LaunchAgents/com.harness.daemon.plist",
        "domain_target": "gui/501",
        "service_target": "gui/501/com.harness.daemon",
        "state": "running",
        "pid": 4321,
        "last_exit_status": 0,
        "status_error": null
      },
      "acp_runtime_probe": {
        "probes": [
          {
            "agent_id": "claude-acp",
            "display_name": "Claude",
            "binary_present": true,
            "auth_state": "ready",
            "version": "0.9.0",
            "install_hint": null
          }
        ],
        "checked_at": "2026-06-15T10:00:30Z"
      },
      "github_api": {
        "buckets": [
          {"resource": "core", "remaining": 4900, "limit": 5000,
           "used": 100, "reset_at": "2026-06-15T11:00:00Z"}
        ],
        "cooling": [
          {"resource": "search", "reason": "secondary_rate_limit", "until_seconds_from_now": 45}
        ],
        "last_hour_network_requests": 42,
        "last_hour_graphql_points": 1280,
        "cache_hits": 17,
        "cache_stale_hits": 3,
        "cache_deferred_hits": 1,
        "deferred_budget": 250,
        "top_operations": [
          {"operation": "listPullRequests", "network_requests": 12, "graphql_points": 480}
        ]
      },
      "workspace": {
        "daemon_root": "/Users/x/.harness/daemon",
        "manifest_path": "/Users/x/.harness/daemon/manifest.json",
        "auth_token_path": "/Users/x/.harness/token",
        "auth_token_present": true,
        "events_path": "/Users/x/.harness/daemon/events.log",
        "database_path": "/Users/x/.harness/daemon/harness.db",
        "database_size_bytes": 65536,
        "last_event": {
          "recorded_at": "2026-06-15T10:00:45Z",
          "level": "info",
          "message": "manifest written"
        }
      },
      "recent_events": [
        {"recorded_at": "2026-06-15T10:00:10Z", "level": "info", "message": "daemon started"},
        {"recorded_at": "2026-06-15T10:00:45Z", "level": "warn", "message": "host bridge reconnect"}
      ]
    }
    """#

  @Test("full diagnostics report maps every field through the wire")
  func fullReportMapsEveryField() throws {
    let data = try #require(daemonPayload.data(using: .utf8))
    let wire = try decoder.decode(DaemonDiagnosticsReportWire.self, from: data)
    let report = DaemonDiagnosticsReport(wire: wire)

    let health = try #require(report.health)
    #expect(health.status == "ok")
    #expect(health.pid == 9876)
    #expect(health.projectCount == 3)
    #expect(health.worktreeCount == 5)
    #expect(health.sessionCount == 2)
    #expect(health.wireVersion == 2)
    #expect(health.logLevel == "info")

    let manifest = try #require(report.manifest)
    #expect(manifest.pid == 1234)
    #expect(manifest.sandboxed == true)
    #expect(manifest.revision == 7)
    #expect(manifest.updatedAt == "2026-06-15T10:01:00Z")
    #expect(manifest.hostBridge.running == true)
    #expect(manifest.hostBridge.socketPath == "/tmp/harness-bridge.sock")
    let codex = try #require(manifest.hostBridge.capabilities["codex"])
    #expect(codex.enabled == true)
    #expect(codex.transport == "websocket")
    #expect(codex.endpoint == "ws://127.0.0.1:9000")
    #expect(codex.metadata["region"] == "local")
    let stamp = try #require(manifest.binaryStamp)
    #expect(stamp.deviceIdentifier == 999)
    #expect(stamp.fileSize == 1_048_576)
    #expect(stamp.modificationTimeIntervalSince1970 == 1_750_000_000.5)

    #expect(report.launchAgent.installed == true)
    #expect(report.launchAgent.domainTarget == "gui/501")
    #expect(report.launchAgent.state == "running")
    #expect(report.launchAgent.pid == 4321)
    #expect(report.launchAgent.lastExitStatus == 0)
    #expect(report.launchAgent.statusError == nil)

    let github = try #require(report.githubApi)
    #expect(github.lastHourNetworkRequests == 42)
    #expect(github.deferredBudget == 250)
    #expect(github.buckets.first?.remaining == 4900)
    #expect(github.cooling.first?.untilSecondsFromNow == 45)
    #expect(github.topOperations.first?.graphqlPoints == 480)

    #expect(report.workspace.daemonRoot == "/Users/x/.harness/daemon")
    #expect(report.workspace.databaseSizeBytes == 65536)
    #expect(report.workspace.lastEvent?.message == "manifest written")

    #expect(report.recentEvents.count == 2)
    #expect(report.recentEvents.first?.message == "daemon started")
    #expect(report.recentEvents.last?.level == "warn")
  }

  @Test("optional sections decode as nil when the daemon omits them")
  func optionalSectionsDecodeAsNil() throws {
    let payload = #"""
      {
        "launch_agent": {
          "installed": false,
          "loaded": false,
          "label": "com.harness.daemon",
          "path": "",
          "domain_target": "",
          "service_target": "",
          "state": null,
          "pid": null,
          "last_exit_status": null,
          "status_error": null
        },
        "workspace": {
          "daemon_root": "/root",
          "manifest_path": "/root/manifest.json",
          "auth_token_path": "/root/token",
          "auth_token_present": false,
          "events_path": "/root/events.log",
          "database_path": "/root/harness.db",
          "database_size_bytes": 0,
          "last_event": null
        },
        "recent_events": []
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(DaemonDiagnosticsReportWire.self, from: data)
    let report = DaemonDiagnosticsReport(wire: wire)

    #expect(report.health == nil)
    #expect(report.manifest == nil)
    #expect(report.githubApi == nil)
    #expect(report.launchAgent.pid == nil)
    #expect(report.workspace.lastEvent == nil)
    #expect(report.recentEvents.isEmpty)
  }
}
