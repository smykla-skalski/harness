import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Settings Actions") {
  @Previewable @State var isConfirmationPresented = false

  Form {
    Section("Actions") {
      SettingsActionButtons(
        daemonOwnership: .managed,
        isLoading: false,
        isRemoveLaunchAgentConfirmationPresented: $isConfirmationPresented,
        reconnect: {},
        refreshDiagnostics: {},
        startDaemon: {},
        installLaunchAgent: {}
      )
    }
  }
  .settingsDetailFormStyle()
  .frame(width: 720)
}
