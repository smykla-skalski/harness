import Foundation

// Map the generated acp runtime-probe wire types to the hand models. The shapes are
// thin mirrors (camelCase of the same fields), so the maps are field-for-field; the
// hand AcpRuntimeProbe keeps its Identifiable conformance and the probe references the
// shared AcpAuthState enum the wire decodes bare.

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
