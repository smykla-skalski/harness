import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct SupervisorUITestForceTickModifier: ViewModifier {
  let store: HarnessMonitorStore

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      content
        .overlay(alignment: .bottomTrailing) {
          Button("Force Supervisor Tick") {
            Task {
              await store.runSupervisorTickForTesting()
            }
          }
          .harnessActionButtonStyle(variant: .borderless, tint: nil)
          .frame(width: 24, height: 24)
          .opacity(0.01)
          .padding(8)
          .accessibilityIdentifier(HarnessMonitorAccessibility.supervisorForceTick)
        }
    } else {
      content
    }
  }
}
