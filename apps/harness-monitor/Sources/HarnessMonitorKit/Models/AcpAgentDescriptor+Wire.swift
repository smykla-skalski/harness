import Foundation

// Map the generated acp config wire types (runtime probe, agent descriptor) to the hand
// models. The shapes are thin mirrors; the descriptor map preserves the hand's non-empty
// validation on id/displayName/launchCommand (the daemon's own decode does not enforce it,
// so the check stays app-side) and renames DoctorProbe to the hand AcpDoctorProbe. These
// back the MonitorConfiguration.runtimeProbe and .acpAgents fields.

private func requireNonEmptyWireString(_ value: String, _ field: String) throws -> String {
  guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: [], debugDescription: "\(field) must not be empty")
    )
  }
  return value
}

extension AcpRuntimeProbe {
  public init(wire: AcpRuntimeProbeWire) {
    self.init(
      agentId: wire.agentId,
      displayName: wire.displayName,
      binaryPresent: wire.binaryPresent,
      authState: wire.authState,
      version: wire.version,
      installHint: wire.installHint
    )
  }
}

extension AcpRuntimeProbeResponse {
  public init(wire: AcpRuntimeProbeResponseWire) {
    self.init(
      probes: wire.probes.map(AcpRuntimeProbe.init(wire:)),
      checkedAt: wire.checkedAt
    )
  }
}

extension AcpDoctorProbe {
  public init(wire: DoctorProbeWire) {
    self.init(command: wire.command, args: wire.args)
  }
}

extension AcpAgentDescriptor {
  public init(wire: AcpAgentDescriptorWire) throws {
    self.init(
      id: try requireNonEmptyWireString(wire.id, "id"),
      displayName: try requireNonEmptyWireString(wire.displayName, "display_name"),
      capabilities: wire.capabilities,
      launchCommand: try requireNonEmptyWireString(wire.launchCommand, "launch_command"),
      launchArgs: wire.launchArgs,
      envPassthrough: wire.envPassthrough,
      modelCatalog: wire.modelCatalog.map(RuntimeModelCatalog.init(wire:)),
      installHint: wire.installHint,
      doctorProbe: AcpDoctorProbe(wire: wire.doctorProbe),
      promptTimeoutSeconds: wire.promptTimeoutSeconds,
      excludedFromInitialDefault: wire.excludedFromInitialDefault,
      bundledWithHarness: wire.bundledWithHarness
    )
  }
}

// The acp transcript response (entries: [TimelineEntry], generated into SummariesWireTypes);
// reuses the TimelineEntry wire map. Backs the /v1/managed-agents/acp/transcript endpoint.
extension AcpTranscriptResponse {
  public init(wire: AcpTranscriptResponseWire) {
    self.init(entries: wire.entries.map(TimelineEntry.init(wire:)))
  }
}
