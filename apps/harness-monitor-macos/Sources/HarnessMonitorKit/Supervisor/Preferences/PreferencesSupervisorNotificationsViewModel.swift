import Foundation
import Observation

@MainActor
@Observable
public final class PreferencesSupervisorNotificationsViewModel {
  public var preferences: SupervisorNotificationPreferences
  public var verboseToolCallAnnouncementsEnabled: Bool
  public var acpCatalogEnabled: Bool
  public var acpCatalogForcedByEnvironment: Bool

  @ObservationIgnored private let userDefaults: UserDefaults

  public init(
    userDefaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.userDefaults = userDefaults
    preferences = SupervisorNotificationPreferences.load(from: userDefaults)
    verboseToolCallAnnouncementsEnabled =
      HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsEnabled(
        userDefaults: userDefaults
      )
    let environmentValue = HarnessMonitorAcpCatalogPreferences.environmentValue(
      from: environment
    )
    acpCatalogForcedByEnvironment = environmentValue != nil
    acpCatalogEnabled =
      environmentValue
      ?? HarnessMonitorAcpCatalogPreferences.storedValue(userDefaults: userDefaults)
  }

  public func isEnabled(
    _ channel: SupervisorNotificationChannel,
    for severity: DecisionSeverity
  ) -> Bool {
    preferences.isEnabled(channel, for: severity)
  }

  public func setEnabled(
    _ enabled: Bool,
    channel: SupervisorNotificationChannel,
    for severity: DecisionSeverity
  ) {
    preferences.setEnabled(enabled, channel: channel, for: severity)
    preferences.save(to: userDefaults)
  }

  public func allowsAny(for severity: DecisionSeverity) -> Bool {
    preferences.allowsAnyDelivery(for: severity)
  }

  public func setAllowed(_ allowed: Bool, for severity: DecisionSeverity) {
    preferences.setAllowed(allowed, for: severity)
    preferences.save(to: userDefaults)
  }

  public func setVerboseToolCallAnnouncementsEnabled(_ enabled: Bool) {
    guard verboseToolCallAnnouncementsEnabled != enabled else {
      return
    }
    verboseToolCallAnnouncementsEnabled = enabled
    userDefaults.set(
      enabled,
      forKey: HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsKey
    )
  }

  public func setAcpCatalogEnabled(_ enabled: Bool) {
    guard !acpCatalogForcedByEnvironment, acpCatalogEnabled != enabled else {
      return
    }
    acpCatalogEnabled = enabled
    userDefaults.set(enabled, forKey: HarnessMonitorAcpCatalogPreferences.appStorageKey)
  }

  public func enabledChannelsDescription(for severity: DecisionSeverity) -> String {
    let channels = SupervisorNotificationChannel.allCases.filter {
      preferences.isEnabled($0, for: severity)
    }
    if channels.isEmpty {
      return "All channels disabled"
    }
    return channels.map(\.title).joined(separator: " · ")
  }
}
