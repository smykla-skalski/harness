import Foundation

extension AgentRegistration {
  /// Agents emitted by the daemon's `spawn_reviewer` auto-spawn helper advertise
  /// the `auto-spawned` capability. The Swift sidebar uses this to surface an
  /// overlay badge so operators can distinguish automation-created reviewers
  /// from operators that joined manually.
  public static let autoSpawnedCapability = "auto-spawned"

  public var isAutoSpawned: Bool {
    capabilities.contains(Self.autoSpawnedCapability)
  }
}
