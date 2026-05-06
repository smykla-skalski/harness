import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Settings Actions") {
  @Previewable @State var isConfirmationPresented = false

  Form {
    Section("Actions") {
      SettingsActionButtons(
        store: SettingsPreviewSupport.makeStore(),
        isLoading: false,
        isRemoveLaunchAgentConfirmationPresented: $isConfirmationPresented
      )
    }
  }
  .settingsDetailFormStyle()
  .frame(width: 720)
}
