import Foundation
import Observation

@MainActor
@Observable
public final class SettingsSupervisorNotificationsViewModel {
  public var settings: SupervisorNotificationSettings
  public var verboseToolCallAnnouncementsEnabled: Bool
  public var acpCatalogEnabled: Bool
  public var acpCatalogForcedByEnvironment: Bool

  @ObservationIgnored private let userDefaults: UserDefaults

  public init(
    userDefaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.userDefaults = userDefaults
    settings = SupervisorNotificationSettings.load(from: userDefaults)
    verboseToolCallAnnouncementsEnabled =
      HarnessMonitorToolCallAnnouncementSettings.verboseAnnouncementsEnabled(
        userDefaults: userDefaults
      )
    let environmentValue = HarnessMonitorAcpCatalogSettings.environmentValue(
      from: environment
    )
    acpCatalogForcedByEnvironment = environmentValue != nil
    acpCatalogEnabled =
      environmentValue
      ?? HarnessMonitorAcpCatalogSettings.storedValue(userDefaults: userDefaults)
  }

  public func isEnabled(
    _ channel: SupervisorNotificationChannel,
    for severity: DecisionSeverity
  ) -> Bool {
    settings.isEnabled(channel, for: severity)
  }

  public func setEnabled(
    _ enabled: Bool,
    channel: SupervisorNotificationChannel,
    for severity: DecisionSeverity
  ) {
    settings.setEnabled(enabled, channel: channel, for: severity)
    settings.save(to: userDefaults)
  }

  public func allowsAny(for severity: DecisionSeverity) -> Bool {
    settings.allowsAnyDelivery(for: severity)
  }

  public func setAllowed(_ allowed: Bool, for severity: DecisionSeverity) {
    settings.setAllowed(allowed, for: severity)
    settings.save(to: userDefaults)
  }

  public func setVerboseToolCallAnnouncementsEnabled(_ enabled: Bool) {
    guard verboseToolCallAnnouncementsEnabled != enabled else {
      return
    }
    verboseToolCallAnnouncementsEnabled = enabled
    userDefaults.set(
      enabled,
      forKey: HarnessMonitorToolCallAnnouncementSettings.verboseAnnouncementsKey
    )
  }

  public func setAcpCatalogEnabled(_ enabled: Bool) {
    guard !acpCatalogForcedByEnvironment, acpCatalogEnabled != enabled else {
      return
    }
    acpCatalogEnabled = enabled
    userDefaults.set(enabled, forKey: HarnessMonitorAcpCatalogSettings.appStorageKey)
  }

  public func enabledChannelsDescription(for severity: DecisionSeverity) -> String {
    let channels = SupervisorNotificationChannel.allCases.filter {
      settings.isEnabled($0, for: severity)
    }
    if channels.isEmpty {
      return "All channels disabled"
    }
    return channels.map(\.title).joined(separator: " · ")
  }
}
