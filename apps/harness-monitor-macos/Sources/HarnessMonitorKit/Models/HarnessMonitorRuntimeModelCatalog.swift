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

/// Reasoning / thinking parameter family published alongside each runtime
/// model. Mirrors `agents::runtime::models::EffortKind` on the daemon side.
public enum EffortKind: String, Codable, Equatable, Sendable, CaseIterable {
  case none
  case thinkingBudget = "thinking_budget"
  case reasoningEffort = "reasoning_effort"

  public var supportsEffort: Bool { self != .none }
}

/// One model offered by a runtime.
public struct RuntimeModel: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let tier: RuntimeModelTier
  public let effortKind: EffortKind
  public let effortValues: [String]

  public var supportsEffort: Bool { effortKind.supportsEffort }

  public init(
    id: String,
    displayName: String,
    tier: RuntimeModelTier,
    effortKind: EffortKind = .none,
    effortValues: [String] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.tier = tier
    self.effortKind = effortKind
    self.effortValues = effortValues
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    tier = try container.decode(RuntimeModelTier.self, forKey: .tier)
    effortKind = try container.decodeIfPresent(EffortKind.self, forKey: .effortKind) ?? .none
    effortValues = try container.decodeIfPresent([String].self, forKey: .effortValues) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case tier
    case effortKind
    case effortValues
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
