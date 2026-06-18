import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for SessionDetail.agents (AgentRegistration). The Rust type is
/// `#[serde(try_from)]` its flat wire::AgentRegistrationWire, and the hand model decodes that wire
/// shape today via convertFromSnakeCase. examples/policy-codegen.rs generates the wire with snake
/// CodingKeys for the plain decoder, and HarnessMonitorAgentModels+Wire.swift replays the hand
/// init's logic: rename session_agent_id/runtime_session_id, collapse the untagged runtime to a
/// String, and recombine managed_agent_id + managed_agent_family.
@Suite("Agent registration wire decoding")
struct AgentRegistrationWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("full registration maps every field, collapsing the tagged runtime")
  func fullRegistrationMapsEveryField() throws {
    let payload = #"""
      {
        "session_agent_id": "agent-1",
        "name": "Claude Worker",
        "runtime": {"kind": "acp", "id": "claude-acp"},
        "descriptor_id": "claude-acp",
        "role": "worker",
        "capabilities": ["fs", "net"],
        "joined_at": "2026-06-18T10:00:00Z",
        "updated_at": "2026-06-18T10:05:00Z",
        "status": "active",
        "runtime_session_id": "rt-sess-1",
        "managed_agent_id": "managed-1",
        "managed_agent_family": "acp",
        "last_activity_at": "2026-06-18T10:04:00Z",
        "current_task_id": "task-1",
        "runtime_capabilities": {
          "runtime": "claude-acp",
          "supports_native_transcript": true,
          "supports_signal_delivery": true,
          "supports_context_injection": false,
          "typical_signal_latency_seconds": 2,
          "supports_readiness_signal": true,
          "hook_points": [
            {"name": "pre_tool", "typical_latency_seconds": 1, "supports_context_injection": true}
          ]
        },
        "persona": {
          "identifier": "reviewer-persona",
          "name": "Reviewer",
          "symbol": {"type": "sf_symbol", "name": "checkmark.seal"},
          "description": "Reviews code"
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(AgentRegistrationWire.self, from: data)
    let registration = try AgentRegistration(wire: wire)

    #expect(registration.agentId == "agent-1")
    #expect(registration.runtime == "claude-acp")
    #expect(registration.role == .worker)
    #expect(registration.status == .active)
    #expect(registration.capabilities == ["fs", "net"])
    #expect(registration.agentSessionId == "rt-sess-1")
    #expect(registration.managedAgent?.kind == .acp)
    #expect(registration.managedAgent?.id == "managed-1")
    #expect(registration.currentTaskId == "task-1")
    #expect(registration.runtimeCapabilities.runtime == "claude-acp")
    #expect(registration.runtimeCapabilities.typicalSignalLatencySeconds == 2)
    #expect(registration.runtimeCapabilities.hookPoints.first?.name == "pre_tool")
    #expect(registration.persona?.identifier == "reviewer-persona")
    #expect(registration.persona?.symbol == .sfSymbol(name: "checkmark.seal"))
    #expect(registration.id == "agent-1")
  }

  @Test("a bare-string runtime is used directly and absent pairs map to nil")
  func bareStringRuntimeAndAbsentOptionals() throws {
    let payload = #"""
      {
        "session_agent_id": "agent-2",
        "name": "TUI",
        "runtime": "claude",
        "role": "leader",
        "joined_at": "2026-06-18T10:00:00Z",
        "updated_at": "2026-06-18T10:00:00Z",
        "status": "idle",
        "runtime_capabilities": {
          "runtime": "claude",
          "supports_native_transcript": false,
          "supports_signal_delivery": false,
          "supports_context_injection": false,
          "typical_signal_latency_seconds": 0
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(AgentRegistrationWire.self, from: data)
    let registration = try AgentRegistration(wire: wire)

    #expect(registration.runtime == "claude")
    #expect(registration.role == .leader)
    #expect(registration.capabilities.isEmpty)
    #expect(registration.agentSessionId == nil)
    #expect(registration.managedAgent == nil)
    #expect(registration.persona == nil)
    #expect(registration.runtimeCapabilities.hookPoints.isEmpty)
  }

  @Test("a half-populated managed-agent pair throws, matching the hand decode")
  func halfManagedAgentPairThrows() throws {
    let payload = #"""
      {
        "session_agent_id": "agent-3",
        "name": "Broken",
        "runtime": "claude",
        "role": "worker",
        "joined_at": "2026-06-18T10:00:00Z",
        "updated_at": "2026-06-18T10:00:00Z",
        "status": "active",
        "managed_agent_id": "managed-3",
        "runtime_capabilities": {
          "runtime": "claude",
          "supports_native_transcript": false,
          "supports_signal_delivery": false,
          "supports_context_injection": false,
          "typical_signal_latency_seconds": 0
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(AgentRegistrationWire.self, from: data)
    #expect(throws: (any Error).self) {
      _ = try AgentRegistration(wire: wire)
    }
  }
}
