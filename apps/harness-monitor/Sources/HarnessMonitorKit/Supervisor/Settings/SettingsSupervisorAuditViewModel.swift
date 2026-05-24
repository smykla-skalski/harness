import Foundation
import Observation

/// View model for the Supervisor Audit settings pane.
///
/// Round-trips the audit retention window through `UserDefaults` so the pane and the
/// retention scheduler agree on the same setting.
@MainActor
@Observable
public final class SettingsSupervisorAuditViewModel: @unchecked Sendable {
  /// Default retention window: 14 days.
  public static let defaultRetentionSeconds: TimeInterval = 14 * 24 * 60 * 60

  public var retentionSeconds: TimeInterval {
    didSet {
      guard retentionSeconds != oldValue else { return }
      userDefaults.set(retentionSeconds, forKey: Self.retentionStorageKey)
    }
  }

  @ObservationIgnored private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    let storedValue = userDefaults.object(forKey: Self.retentionStorageKey) as? Double
    retentionSeconds = storedValue.flatMap(Self.normalize) ?? Self.defaultRetentionSeconds
  }

  static var retentionStorageKey: String {
    SupervisorSettingsDefaults.auditRetentionSecondsKey
  }

  private static func normalize(_ value: Double) -> TimeInterval? {
    guard value.isFinite, value > 0 else { return nil }
    return value
  }
}
