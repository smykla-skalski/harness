import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the acp agent descriptor, generated from catalog/mod.rs.
/// The descriptor decodes through the plain decoder; the daemon-only spawn/session config
/// fields are dropped from the wire (and harmlessly ignored when present), model_catalog
/// reuses the runtime-catalog wire, and the map preserves the hand's non-empty validation.
/// These back the MonitorConfiguration.acpAgents field.
@Suite("Acp agent descriptor wire type")
struct AcpAgentDescriptorWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a descriptor and ignores the daemon-only config fields")
  func decodesDescriptor() throws {
    let wire = try decoder.decode(
      AcpAgentDescriptorWire.self, from: Data(descriptorFixture.utf8)
    )
    #expect(wire.id == "copilot")
    #expect(wire.displayName == "GitHub Copilot")
    #expect(wire.capabilities == ["fs_read", "fs_write"])
    #expect(wire.launchArgs == ["--acp"])
    #expect(wire.envPassthrough == ["GITHUB_TOKEN"])
    #expect(wire.installHint == "brew install copilot")
    #expect(wire.promptTimeoutSeconds == 600)
    #expect(wire.excludedFromInitialDefault)
    #expect(!wire.bundledWithHarness)
    #expect(wire.doctorProbe.command == "copilot")
    #expect(wire.doctorProbe.args == ["--version"])

    let catalog = try #require(wire.modelCatalog)
    #expect(catalog.runtime == "copilot")
    #expect(catalog.default == "gpt-5")
    #expect(catalog.models.first?.tier == .balanced)
  }

  @Test("maps a decoded descriptor to the hand model")
  func mapsDescriptor() throws {
    let wire = try decoder.decode(
      AcpAgentDescriptorWire.self, from: Data(descriptorFixture.utf8)
    )
    let descriptor = try AcpAgentDescriptor(wire: wire)
    #expect(descriptor.id == "copilot")
    #expect(descriptor.capabilities == ["fs_read", "fs_write"])
    #expect(descriptor.modelCatalog?.runtime == "copilot")
    #expect(descriptor.doctorProbe == AcpDoctorProbe(command: "copilot", args: ["--version"]))
    #expect(descriptor.excludedFromInitialDefault)
  }

  @Test("rejects a descriptor with an empty required string")
  func rejectsEmptyId() throws {
    let wire = try decoder.decode(
      AcpAgentDescriptorWire.self, from: Data(emptyIdFixture.utf8)
    )
    #expect(throws: DecodingError.self) {
      _ = try AcpAgentDescriptor(wire: wire)
    }
  }
}

private let descriptorFixture = """
  {
    "id": "copilot",
    "display_name": "GitHub Copilot",
    "capabilities": ["fs_read", "fs_write"],
    "launch_command": "copilot",
    "launch_args": ["--acp"],
    "env_passthrough": ["GITHUB_TOKEN"],
    "spawn_configuration": { "kind": "descriptor_runtime" },
    "model_catalog": {
      "runtime": "copilot",
      "models": [{ "id": "gpt-5", "display_name": "GPT-5", "tier": "balanced" }],
      "default": "gpt-5",
      "cheapest_fastest": "gpt-5"
    },
    "install_hint": "brew install copilot",
    "session_configuration": { "model": { "kind": "disabled" }, "effort": { "kind": "disabled" } },
    "doctor_probe": { "command": "copilot", "args": ["--version"] },
    "prompt_timeout_seconds": 600,
    "excluded_from_initial_default": true,
    "bundled_with_harness": false
  }
  """

private let emptyIdFixture = """
  {
    "id": "   ",
    "display_name": "Blank",
    "capabilities": [],
    "launch_command": "blank",
    "launch_args": [],
    "env_passthrough": [],
    "doctor_probe": { "command": "blank", "args": [] }
  }
  """
