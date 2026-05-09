import Foundation
import HarnessMonitorKit

struct LaunchPresetSnapshot: Codable, Sendable, Equatable {
  enum Mode: String, Codable, Sendable {
    case terminal
    case codex
  }

  var mode: Mode
  var providerStorageKey: String?
  var role: String?
  var fallbackRole: String?
  var personaID: String?
  var modelByRuntime: [String: String]
  var customModelByRuntime: [String: String]
  var effortByRuntime: [String: String]
  var rows: Int
  var cols: Int
  var codexMode: String?
  var codexModel: String?
  var customCodexModel: String?
  var codexEffort: String?

  init(
    mode: Mode,
    providerStorageKey: String? = nil,
    role: String? = nil,
    fallbackRole: String? = nil,
    personaID: String? = nil,
    modelByRuntime: [String: String] = [:],
    customModelByRuntime: [String: String] = [:],
    effortByRuntime: [String: String] = [:],
    rows: Int = 32,
    cols: Int = 120,
    codexMode: String? = nil,
    codexModel: String? = nil,
    customCodexModel: String? = nil,
    codexEffort: String? = nil
  ) {
    self.mode = mode
    self.providerStorageKey = providerStorageKey
    self.role = role
    self.fallbackRole = fallbackRole
    self.personaID = personaID
    self.modelByRuntime = modelByRuntime
    self.customModelByRuntime = customModelByRuntime
    self.effortByRuntime = effortByRuntime
    self.rows = rows
    self.cols = cols
    self.codexMode = codexMode
    self.codexModel = codexModel
    self.customCodexModel = customCodexModel
    self.codexEffort = codexEffort
  }

  var providerID: String? {
    providerStorageKey
      .flatMap(AgentLaunchSelection.init(storageKey:))
      .map(HarnessMonitorAgentLaunchDefaults.providerID(for:))
  }
}

enum LaunchPresetDefaults {
  static let storageKey = "harness.monitor.workspace.lastLaunchPreset"

  static func decode(from raw: String?) -> LaunchPresetSnapshot? {
    guard let raw, let data = raw.data(using: .utf8) else {
      return nil
    }
    return try? JSONDecoder().decode(LaunchPresetSnapshot.self, from: data)
  }

  static func encode(_ snapshot: LaunchPresetSnapshot) -> String? {
    guard let data = try? JSONEncoder().encode(snapshot) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  @MainActor
  static func write(_ snapshot: LaunchPresetSnapshot) {
    guard let raw = encode(snapshot) else { return }
    UserDefaults.standard.set(raw, forKey: storageKey)
  }

  @MainActor
  static func read(userDefaults: UserDefaults = .standard) -> LaunchPresetSnapshot? {
    guard var snapshot = decode(from: userDefaults.string(forKey: storageKey)) else {
      return nil
    }
    if HarnessMonitorAgentLaunchDefaults.isImplicitLegacyTerminalCopilot(
      snapshot.providerStorageKey,
      userDefaults: userDefaults
    ) {
      snapshot.providerStorageKey = nil
    }
    return snapshot
  }

  @MainActor
  static func blocksInitialAcpDefault(_ snapshot: LaunchPresetSnapshot) -> Bool {
    switch snapshot.mode {
    case .codex:
      true
    case .terminal:
      snapshot.providerStorageKey != nil
    }
  }

}
