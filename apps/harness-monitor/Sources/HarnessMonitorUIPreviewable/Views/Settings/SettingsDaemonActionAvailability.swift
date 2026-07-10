import HarnessMonitorKit

public struct SettingsDaemonActionAvailability: Equatable, Sendable {
  public let showsManagedControls: Bool
  public let showsExternalDevCommand: Bool

  public init(
    daemonOwnership: DaemonOwnership,
    usesRemoteDaemon: Bool
  ) {
    showsManagedControls = !usesRemoteDaemon && daemonOwnership == .managed
    showsExternalDevCommand = !usesRemoteDaemon && daemonOwnership == .external
  }
}
