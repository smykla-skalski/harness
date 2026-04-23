import Foundation
import UserNotifications

public enum SupervisorNotificationChannel: String, CaseIterable, Hashable, Identifiable, Sendable {
  case banner
  case notificationCenter
  case lockScreen
  case sound
  case badge

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .banner: "Banner"
    case .notificationCenter: "Notification Center"
    case .lockScreen: "Lock Screen"
    case .sound: "Sound"
    case .badge: "Badge"
    }
  }
}

public struct SupervisorNotificationPreferences: Equatable, Sendable {
  private var enabledChannels: [DecisionSeverity: Set<SupervisorNotificationChannel>]

  public init() {
    enabledChannels = Self.defaultChannels
  }

  public init(enabledChannels: [DecisionSeverity: Set<SupervisorNotificationChannel>]) {
    self.enabledChannels = enabledChannels
  }

  public static func load(from userDefaults: UserDefaults = .standard) -> Self {
    var enabledChannels = defaultChannels
    for severity in DecisionSeverity.allCases {
      for channel in SupervisorNotificationChannel.allCases {
        let key = storageKey(for: severity, channel: channel)
        guard let stored = userDefaults.object(forKey: key) as? Bool else {
          continue
        }
        if stored {
          enabledChannels[severity, default: []].insert(channel)
        } else {
          enabledChannels[severity, default: []].remove(channel)
        }
      }
    }
    return Self(enabledChannels: enabledChannels)
  }

  public func save(to userDefaults: UserDefaults = .standard) {
    for severity in DecisionSeverity.allCases {
      for channel in SupervisorNotificationChannel.allCases {
        userDefaults.set(
          isEnabled(channel, for: severity),
          forKey: Self.storageKey(for: severity, channel: channel)
        )
      }
    }
  }

  public func isEnabled(
    _ channel: SupervisorNotificationChannel,
    for severity: DecisionSeverity
  ) -> Bool {
    enabledChannels[severity, default: []].contains(channel)
  }

  public mutating func setEnabled(
    _ enabled: Bool,
    channel: SupervisorNotificationChannel,
    for severity: DecisionSeverity
  ) {
    if enabled {
      enabledChannels[severity, default: []].insert(channel)
    } else {
      enabledChannels[severity, default: []].remove(channel)
    }
  }

  public func foregroundPresentationOptions(
    for severity: DecisionSeverity
  ) -> UNNotificationPresentationOptions {
    var options: UNNotificationPresentationOptions = []
    if isEnabled(.banner, for: severity) {
      options.insert(.banner)
    }
    if isEnabled(.notificationCenter, for: severity) {
      options.insert(.list)
    }
    if isEnabled(.sound, for: severity) {
      options.insert(.sound)
    }
    if isEnabled(.badge, for: severity) {
      options.insert(.badge)
    }
    return options
  }

  public func requestSound(for severity: DecisionSeverity) -> UNNotificationSound? {
    guard isEnabled(.sound, for: severity) else {
      return nil
    }
    return severity == .critical ? .defaultCritical : .default
  }

  public func allowsAnyDelivery(for severity: DecisionSeverity) -> Bool {
    SupervisorNotificationChannel.allCases.contains { channel in
      isEnabled(channel, for: severity)
    }
  }

  public mutating func setAllowed(_ allowed: Bool, for severity: DecisionSeverity) {
    enabledChannels[severity] = allowed ? Self.defaultChannels[severity, default: []] : []
  }

  public static func defaultChannels(
    for severity: DecisionSeverity
  ) -> Set<SupervisorNotificationChannel> {
    defaultChannels[severity, default: []]
  }

  private static let defaultChannels: [DecisionSeverity: Set<SupervisorNotificationChannel>] = [
    .info: [.banner, .notificationCenter, .lockScreen],
    .warn: [.banner, .notificationCenter, .lockScreen, .sound],
    .needsUser: [.banner, .notificationCenter, .lockScreen, .sound, .badge],
    .critical: [.banner, .notificationCenter, .lockScreen, .sound, .badge],
  ]

  private static func storageKey(
    for severity: DecisionSeverity,
    channel: SupervisorNotificationChannel
  ) -> String {
    "supervisor.notifications.\(severity.rawValue).\(channel.rawValue)"
  }
}
