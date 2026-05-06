import SwiftUI

#Preview("Settings Paths") {
  Form {
    SettingsPathsSection(
      paths: SettingsDiagnosticsPaths(
        launchAgentPath: "/Users/example/Library/LaunchAgents/io.harness.daemon.plist",
        launchAgentDomain: "gui/501",
        launchAgentService: "gui/501/io.harness.daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        databasePath: "/Users/example/Library/Application Support/harness/daemon/harness.db"
      )
    )
  }
  .settingsDetailFormStyle()
  .frame(width: 720)
}
