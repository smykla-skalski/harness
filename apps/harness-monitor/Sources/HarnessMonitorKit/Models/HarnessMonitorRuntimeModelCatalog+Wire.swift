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
