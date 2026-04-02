import SwiftUI

struct PreferencesDiagnosticsPaths {
  let launchAgentPath: String
  let launchAgentDomain: String?
  let launchAgentService: String?
  let manifestPath: String
  let authTokenPath: String
  let eventsPath: String
  let cacheRoot: String
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
      pathRow("Cache Root", value: paths.cacheRoot)
    }
  }

  private func pathRow(_ title: String, value: String) -> some View {
    LabeledContent(title) {
      Text(value)
        .scaledFont(.caption.monospaced())
        .truncationMode(.middle)
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
        cacheRoot: "/Users/example/Library/Application Support/harness/daemon/cache/projects"
      )
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 720)
}
