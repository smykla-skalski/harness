import HarnessMonitorKit
import SwiftUI

#Preview("Settings Diagnostics Overview") {
  let store = SettingsPreviewSupport.makeStore()

  Form {
    SettingsDiagnosticsOverview(
      launchAgent: store.daemonStatus?.launchAgent,
      mcpStatus: store.mcpStatus,
      tokenPresent: store.diagnostics?.workspace.authTokenPresent ?? false,
      projectCount: store.daemonStatus?.projectCount ?? 0,
      worktreeCount: store.daemonStatus?.worktreeCount ?? 0,
      sessionCount: store.daemonStatus?.sessionCount ?? 0,
      externalSessionCount: store.sessions.filter { $0.externalOrigin != nil }.count,
      lastExternalSessionAttachOutcome: store.lastExternalSessionAttachOutcome?.message,
      lastExternalSessionAttachSucceeded: store.lastExternalSessionAttachOutcome?.succeeded,
      lastEvent: store.diagnostics?.workspace.lastEvent,
      repairLaunchAgent: { await store.repairLaunchAgent() }
    )
  }
  .settingsDetailFormStyle()
  .frame(width: 560)
}
