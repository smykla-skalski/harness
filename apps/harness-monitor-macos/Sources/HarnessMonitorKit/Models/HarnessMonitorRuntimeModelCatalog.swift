import Foundation

/// Cost/speed tier published by the daemon's runtime model catalog. Used by
/// the model picker UI for ordering and by E2E tests for picking the
/// cheapest/fastest model.
public enum RuntimeModelTier: String, Codable, Equatable, Sendable, CaseIterable {
  case fast
  case balanced
  case max

  public var sortOrder: Int {
    switch self {
    case .fast: 0
    case .balanced: 1
    case .max: 2
    }
  }
}

/// One model offered by a runtime.
public struct RuntimeModel: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let tier: RuntimeModelTier

  public init(id: String, displayName: String, tier: RuntimeModelTier) {
    self.id = id
    self.displayName = displayName
    self.tier = tier
  }
}

/// All models a single runtime can spawn with.
public struct RuntimeModelCatalog: Codable, Equatable, Identifiable, Sendable {
  public let runtime: String
  public let models: [RuntimeModel]
  public let `default`: String
  public let cheapestFastest: String

  public var id: String { runtime }

  public init(
    runtime: String,
    models: [RuntimeModel],
    default defaultModel: String,
    cheapestFastest: String
  ) {
    self.runtime = runtime
    self.models = models
    self.default = defaultModel
    self.cheapestFastest = cheapestFastest
  }
}

/// Initial configuration payload pushed by the daemon on every WebSocket
/// connect. Carries persona registry and per-runtime model catalogs.
public struct MonitorConfiguration: Codable, Equatable, Sendable {
  public let personas: [AgentPersona]
  public let runtimeModels: [RuntimeModelCatalog]

  public init(personas: [AgentPersona], runtimeModels: [RuntimeModelCatalog]) {
    self.personas = personas
    self.runtimeModels = runtimeModels
  }

  public func catalog(forRuntime runtime: String) -> RuntimeModelCatalog? {
    runtimeModels.first { $0.runtime == runtime }
  }
}
