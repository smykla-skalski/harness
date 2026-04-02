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
  let launchAgentPath: String
  let launchAgentDomain: String?
  let launchAgentService: String?
  let manifestPath: String
  let authTokenPath: String
  let eventsPath: String
  let cacheRoot: String

  var body: some View {
    Section("Paths") {
      if let domain = launchAgentDomain, !domain.isEmpty {
        pathRow("Launchd Domain", value: domain)
      }
      if let service = launchAgentService, !service.isEmpty {
        pathRow("Service Target", value: service)
      }
      pathRow("Launch Agent", value: launchAgentPath)
      pathRow("Manifest", value: manifestPath)
      pathRow("Auth Token", value: authTokenPath)
      pathRow("Events Log", value: eventsPath)
      pathRow("Cache Root", value: cacheRoot)
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
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    PreferencesPathsSection(
      launchAgentPath: store.daemonStatus?.launchAgent.path ?? "Unavailable",
      launchAgentDomain: store.daemonStatus?.launchAgent.domainTarget,
      launchAgentService: store.daemonStatus?.launchAgent.serviceTarget,
      manifestPath: store.diagnostics?.workspace.manifestPath ?? "Unavailable",
      authTokenPath: store.diagnostics?.workspace.authTokenPath ?? "Unavailable",
      eventsPath: store.diagnostics?.workspace.eventsPath ?? "Unavailable",
      cacheRoot: store.diagnostics?.workspace.cacheRoot ?? "Unavailable"
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 720)
}
