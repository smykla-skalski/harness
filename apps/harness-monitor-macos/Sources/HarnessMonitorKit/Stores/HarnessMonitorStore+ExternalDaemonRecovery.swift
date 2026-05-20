import Foundation

extension HarnessMonitorStore {
  func externalDaemonRecoveryFeedback(
    for error: any Error,
    daemonCommand: String
  ) -> ExternalDaemonRecoveryFeedback {
    guard let daemonError = error as? DaemonControlError else {
      return .generic(daemonCommand: daemonCommand)
    }

    switch daemonError {
    case .externalDaemonManifestStale(let manifestPath):
      return .staleManifest(
        manifestPath: manifestPath,
        daemonCommand: daemonCommand,
        profileLabel: externalDaemonProfileLabel()
      )
    case .externalDaemonOffline(let manifestPath):
      return .offline(
        manifestPath: manifestPath,
        daemonCommand: daemonCommand,
        profileLabel: externalDaemonProfileLabel()
      )
    default:
      return .generic(
        daemonCommand: daemonCommand,
        message: daemonError.errorDescription
      )
    }
  }

  private func externalDaemonProfileLabel() -> String {
    guard let lane = HarnessMonitorPaths.runtimeLane() else {
      return "the default lane"
    }
    return "lane \"\(lane)\""
  }
}

struct ExternalDaemonRecoveryFeedback {
  let title: String
  let message: String
  let offlineMessage: String
  let details: ActionFeedbackDetails
  let primaryAction: ActionFeedbackAction

  static func staleManifest(
    manifestPath: String,
    daemonCommand: String,
    profileLabel: String
  ) -> Self {
    Self(
      title: "Restart background helper",
      message: "Monitor will reconnect to \(profileLabel) after you restart the helper in Terminal",
      offlineMessage: "Background helper stopped. Restart it to reconnect",
      details: details(
        summary: "Restarting replaces the stale daemon state; it does not delete lane data",
        manifestPath: manifestPath,
        daemonCommand: daemonCommand
      ),
      primaryAction: copyRestartCommandAction(daemonCommand)
    )
  }

  static func offline(
    manifestPath: String,
    daemonCommand: String,
    profileLabel: String
  ) -> Self {
    Self(
      title: "Start background helper",
      message: "Start the helper in Terminal to load live sessions for \(profileLabel)",
      offlineMessage: "Background helper is not running. Start it to load live sessions",
      details: details(
        summary: "Use this command in Terminal when you want Monitor to reconnect",
        manifestPath: manifestPath,
        daemonCommand: daemonCommand
      ),
      primaryAction: copyRestartCommandAction(daemonCommand)
    )
  }

  static func generic(daemonCommand: String, message: String? = nil) -> Self {
    Self(
      title: "Start background helper",
      message: message ?? "Start the helper in Terminal to load live sessions",
      offlineMessage: message ?? "Background helper unavailable. Start it to load live sessions",
      details: details(
        summary: "Use this command in Terminal when you want Monitor to reconnect",
        manifestPath: nil,
        daemonCommand: daemonCommand
      ),
      primaryAction: copyRestartCommandAction(daemonCommand)
    )
  }

  private static func details(
    summary: String,
    manifestPath: String?,
    daemonCommand: String
  ) -> ActionFeedbackDetails {
    var rows = [ActionFeedbackDetailRow(label: "Mode", value: "External daemon")]
    if let manifestPath {
      rows.append(ActionFeedbackDetailRow(label: "Manifest", value: manifestPath))
    }
    return ActionFeedbackDetails(
      disclosureLabel: "restart details",
      summary: summary,
      rows: rows,
      command: daemonCommand
    )
  }

  private static func copyRestartCommandAction(_ daemonCommand: String) -> ActionFeedbackAction {
    ActionFeedbackAction(
      title: "Copy Terminal restart command",
      systemImage: "doc.on.clipboard",
      kind: .copy(text: daemonCommand),
      successAnnouncement: "Terminal restart command copied"
    )
  }
}
