import Foundation

public enum HarnessMonitorToolCallAnnouncementPreferences {
  public static let verboseAnnouncementsKey = "harness.tool-call.verbose-announcements"
  public static let verboseAnnouncementsDefault = false

  public static func registrationDefaults() -> [String: Any] {
    [verboseAnnouncementsKey: verboseAnnouncementsDefault]
  }

  public static func verboseAnnouncementsEnabled(
    userDefaults: UserDefaults = .standard
  ) -> Bool {
    userDefaults.object(forKey: verboseAnnouncementsKey) as? Bool
      ?? verboseAnnouncementsDefault
  }
}
