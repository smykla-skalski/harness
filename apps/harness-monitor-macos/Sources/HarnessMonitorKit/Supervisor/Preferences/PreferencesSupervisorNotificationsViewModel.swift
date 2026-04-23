import Foundation
import Observation

@MainActor
@Observable
public final class PreferencesSupervisorNotificationsViewModel {
  public var preferences: SupervisorNotificationPreferences

  @ObservationIgnored private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    preferences = SupervisorNotificationPreferences.load(from: userDefaults)
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
