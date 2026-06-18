import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the acp runtime-probe response, generated from
/// probe.rs. The probe decodes through the plain decoder (snake_case CodingKeys, no
/// convertFromSnakeCase) and references the shared AcpAuthState enum bare; the map is a
/// thin field-for-field mirror. The /v1/runtimes/probe endpoint is rerouted.
@Suite("Acp runtime probe wire type")
struct AcpProbeWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a runtime probe response through the plain decoder")
  func decodesProbeResponse() throws {
    let wire = try decoder.decode(
      AcpRuntimeProbeResponseWire.self, from: Data(probeFixture.utf8)
    )
    #expect(wire.checkedAt == "2026-06-18T00:00:00Z")
    #expect(wire.probes.count == 2)

    let ready = try #require(wire.probes.first)
    #expect(ready.agentId == "copilot")
    #expect(ready.displayName == "GitHub Copilot")
    #expect(ready.binaryPresent)
    #expect(ready.authState == .ready)
    #expect(ready.version == "1.2.3")
    #expect(ready.installHint == nil)

    let missing = wire.probes[1]
    #expect(missing.agentId == "gemini")
    #expect(missing.authState == .unavailable)
    #expect(!missing.binaryPresent)
    #expect(missing.version == nil)
    #expect(missing.installHint == "brew install gemini")
  }

  @Test("maps a decoded probe response to the hand model")
  func mapsProbeResponse() throws {
    let wire = try decoder.decode(
      AcpRuntimeProbeResponseWire.self, from: Data(probeFixture.utf8)
    )
    let response = AcpRuntimeProbeResponse(wire: wire)

    #expect(response.checkedAt == "2026-06-18T00:00:00Z")
    #expect(response.probes.count == 2)
    let ready = try #require(response.probes.first)
    #expect(ready.id == "copilot")
    #expect(ready.authState == .ready)
    #expect(ready.version == "1.2.3")
    #expect(response.probes[1].authState == .unavailable)
  }
}

private let probeFixture = """
  {
    "probes": [
      {
        "agent_id": "copilot",
        "display_name": "GitHub Copilot",
        "binary_present": true,
        "auth_state": "ready",
        "version": "1.2.3",
        "install_hint": null
      },
      {
        "agent_id": "gemini",
        "display_name": "Gemini",
        "binary_present": false,
        "auth_state": "unavailable",
        "install_hint": "brew install gemini"
      }
    ],
    "checked_at": "2026-06-18T00:00:00Z"
  }
  """
