import SwiftUI

public struct SettingsDiagnosticsPaths: Sendable {
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

struct SettingsPathsSection: View {
  let paths: SettingsDiagnosticsPaths

  var body: some View {
    Section {
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
    } header: {
      Text("Paths")
        .harnessNativeFormSectionHeader()
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
