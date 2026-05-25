import SwiftUI

struct SettingsScrollRestorationSectionKey: EnvironmentKey {
  static let defaultValue: SettingsSection? = nil
}

struct SettingsScrollRestorationSuspendedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var settingsScrollRestorationSection: SettingsSection? {
    get { self[SettingsScrollRestorationSectionKey.self] }
    set { self[SettingsScrollRestorationSectionKey.self] = newValue }
  }

  var settingsScrollRestorationSuspended: Bool {
    get { self[SettingsScrollRestorationSuspendedKey.self] }
    set { self[SettingsScrollRestorationSuspendedKey.self] = newValue }
  }
}

struct SettingsScrollRestoreRequest: Equatable {
  var id: UInt64
  var offset: CGFloat
}
