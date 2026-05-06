import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Actions") {
  @Previewable @State var isConfirmationPresented = false

  Form {
    Section("Actions") {
      PreferencesActionButtons(
        store: PreferencesPreviewSupport.makeStore(),
        isLoading: false,
        isRemoveLaunchAgentConfirmationPresented: $isConfirmationPresented
      )
    }
  }
  .preferencesDetailFormStyle()
  .frame(width: 720)
}
