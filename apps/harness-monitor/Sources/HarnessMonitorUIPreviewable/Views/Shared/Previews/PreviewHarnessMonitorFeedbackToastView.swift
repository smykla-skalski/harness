import HarnessMonitorKit
import SwiftUI

private enum DaemonRecoveryToastPreview {
  static let manifestPath =
    "/Users/monitor/Library/Group Containers/Q498EB36N4.io.harnessmonitor/"
    + "runtime-lanes/monitor/harness/daemon/manifest.json"
  static let restartCommand =
    "HARNESS_MONITOR_RUNTIME_LANE='monitor' "
    + "HARNESS_DAEMON_DATA_HOME='/Users/monitor/Library/Group Containers/"
    + "Q498EB36N4.io.harnessmonitor/runtime-lanes/monitor' "
    + "HARNESS_CODEX_WS_PORT='20336' harness-daemon dev"

  @MainActor
  static func makeToast() -> ToastSlice {
    let toast = ToastSlice()
    toast.warningDismissDelay = .seconds(120)
    toast.presentWarning(
      "Monitor will reconnect to lane \"monitor\" after you restart the helper in Terminal",
      title: "Restart background helper",
      details: ActionFeedbackDetails(
        disclosureLabel: "restart details",
        summary: "Restarting replaces the stale daemon state; it does not delete lane data.",
        rows: [
          ActionFeedbackDetailRow(label: "Mode", value: "External daemon"),
          ActionFeedbackDetailRow(label: "Manifest", value: manifestPath),
        ],
        command: restartCommand
      ),
      primaryAction: ActionFeedbackAction(
        title: "Copy Terminal restart command",
        systemImage: "doc.on.clipboard",
        kind: .copy(text: restartCommand),
        successAnnouncement: "Terminal restart command copied"
      )
    )
    return toast
  }
}

#Preview(traits: .fixedLayout(width: 560, height: 170)) {
  HarnessMonitorFeedbackToastView(toast: DaemonRecoveryToastPreview.makeToast())
    .frame(width: 540)
    .padding(10)
}

#Preview(traits: .fixedLayout(width: 680, height: 360)) {
  HarnessMonitorFeedbackToastView(
    toast: DaemonRecoveryToastPreview.makeToast(),
    detailsInitiallyExpanded: true
  )
  .frame(width: 660)
  .padding(10)
}
