import SwiftUI

public struct PreferencesDiagnosticsPaths {
  public let launchAgentPath: String
  public let launchAgentDomain: String?
  public let launchAgentService: String?
  public let manifestPath: String
  public let authTokenPath: String
  public let eventsPath: String
  public let databasePath: String

  public init(
    launchAgentPath: String,
    launchAgentDomain: String?,
    launchAgentService: String?,
    manifestPath: String,
    authTokenPath: String,
    eventsPath: String,
    databasePath: String
  ) {
    self.launchAgentPath = launchAgentPath
    self.launchAgentDomain = launchAgentDomain
    self.launchAgentService = launchAgentService
    self.manifestPath = manifestPath
    self.authTokenPath = authTokenPath
    self.eventsPath = eventsPath
    self.databasePath = databasePath
  }
}

struct PreferencesPathsSection: View {
  let paths: PreferencesDiagnosticsPaths

  var body: some View {
    Section("Paths") {
      if let domain = paths.launchAgentDomain, !domain.isEmpty {
        pathRow("Launchd Domain", value: domain)
      }
      if let service = paths.launchAgentService, !service.isEmpty {
        pathRow("Service Target", value: service)
      }
      pathRow("Launch Agent", value: paths.launchAgentPath)
      pathRow("Manifest", value: paths.manifestPath)
      pathRow("Auth Token", value: paths.authTokenPath)
      pathRow("Events Log", value: paths.eventsPath)
      pathRow("Database", value: paths.databasePath)
    }
  }

  private func pathRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(abbreviateHomePath(value))
        .scaledFont(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }
}

#Preview("Preferences Paths") {
  Form {
    PreferencesPathsSection(
      paths: PreferencesDiagnosticsPaths(
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
  .preferencesDetailFormStyle()
  .frame(width: 720)
}
