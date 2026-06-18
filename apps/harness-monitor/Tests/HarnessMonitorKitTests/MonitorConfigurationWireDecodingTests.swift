import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the /v1/config + WebSocket config-push payload (Rust
/// WsConfigPayload). The payload decodes through the plain decoder, nesting the four
/// generated config wire clusters, and maps to the hand MonitorConfiguration. Both the
/// HTTP configuration() endpoint and the WebSocket config push are rerouted onto it.
@Suite("Monitor configuration wire type")
struct MonitorConfigurationWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes the full config payload through the plain decoder")
  func decodesConfig() throws {
    let wire = try decoder.decode(WsConfigPayloadWire.self, from: Data(configFixture.utf8))
    #expect(wire.personas.count == 1)
    #expect(wire.runtimeModels.count == 1)
    #expect(wire.acpAgents.count == 1)
    #expect(wire.personas.first?.identifier == "code-reviewer")
    #expect(wire.runtimeModels.first?.default == "opus")
    #expect(wire.acpAgents.first?.id == "copilot")
    #expect(wire.runtimeProbe?.probes.first?.authState == .ready)
  }

  @Test("maps a decoded config payload to the hand model")
  func mapsConfig() throws {
    let wire = try decoder.decode(WsConfigPayloadWire.self, from: Data(configFixture.utf8))
    let config = try MonitorConfiguration(wire: wire)
    #expect(config.personas.first?.symbol == .sfSymbol(name: "eye"))
    #expect(config.runtimeModels.first?.models.first?.tier == .max)
    #expect(config.acpAgents.first?.doctorProbe.command == "copilot")
    #expect(config.runtimeProbe?.checkedAt == "2026-06-18T00:00:00Z")
  }

  @Test("defaults acp agents and probe when the payload omits them")
  func defaultsOptionalFields() throws {
    let wire = try decoder.decode(WsConfigPayloadWire.self, from: Data(minimalFixture.utf8))
    let config = try MonitorConfiguration(wire: wire)
    #expect(config.acpAgents.isEmpty)
    #expect(config.runtimeProbe == nil)
    #expect(config.personas.count == 1)
  }
}

private let configFixture = """
  {
    "personas": [
      {
        "identifier": "code-reviewer",
        "name": "Reviewer",
        "symbol": { "type": "sf_symbol", "name": "eye" },
        "description": "Reviews changes"
      }
    ],
    "runtime_models": [
      {
        "runtime": "claude",
        "models": [{ "id": "opus", "display_name": "Opus", "tier": "max" }],
        "default": "opus",
        "cheapest_fastest": "opus"
      }
    ],
    "acp_agents": [
      {
        "id": "copilot",
        "display_name": "Copilot",
        "capabilities": [],
        "launch_command": "copilot",
        "launch_args": [],
        "env_passthrough": [],
        "doctor_probe": { "command": "copilot", "args": [] }
      }
    ],
    "runtime_probe": {
      "probes": [
        {
          "agent_id": "copilot",
          "display_name": "Copilot",
          "binary_present": true,
          "auth_state": "ready"
        }
      ],
      "checked_at": "2026-06-18T00:00:00Z"
    }
  }
  """

private let minimalFixture = """
  {
    "personas": [
      {
        "identifier": "worker",
        "name": "Worker",
        "symbol": { "type": "asset", "name": "badge" },
        "description": "Does the work"
      }
    ],
    "runtime_models": []
  }
  """
