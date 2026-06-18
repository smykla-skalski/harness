import Foundation

// Map the generated runtime-model-catalog wire types to the hand models. The shapes are
// thin mirrors and tier/effortKind reference the shared RuntimeModelTier/EffortKind enums
// the wire decodes bare, so no enum conversion is needed. These back the
// MonitorConfiguration.runtimeModels field and AcpAgentDescriptor.modelCatalog.

extension RuntimeModel {
  public init(wire: RuntimeModelWire) {
    self.init(
      id: wire.id,
      displayName: wire.displayName,
      tier: wire.tier,
      effortKind: wire.effortKind,
      effortValues: wire.effortValues
    )
  }
}

extension RuntimeModelCatalog {
  public init(wire: RuntimeModelCatalogWire) {
    self.init(
      runtime: wire.runtime,
      models: wire.models.map(RuntimeModel.init(wire:)),
      default: wire.default,
      cheapestFastest: wire.cheapestFastest
    )
  }
}

// The /v1/config + WebSocket config-push payload (Rust WsConfigPayload). Aggregates the
// four generated config wire clusters; the acpAgents map throws to preserve the
// descriptor's non-empty validation, so this init throws too.
extension MonitorConfiguration {
  public init(wire: WsConfigPayloadWire) throws {
    self.init(
      personas: wire.personas.map(AgentPersona.init(wire:)),
      runtimeModels: wire.runtimeModels.map(RuntimeModelCatalog.init(wire:)),
      acpAgents: try wire.acpAgents.map(AcpAgentDescriptor.init(wire:)),
      runtimeProbe: wire.runtimeProbe.map(AcpRuntimeProbeResponse.init(wire:))
    )
  }
}
