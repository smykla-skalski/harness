import HarnessMonitorKit
import SwiftUI

private enum SleepPreventionToolbarSymbolLayout {
  static let size: CGFloat = 14
}

struct SleepPreventionToolbarPresentation: Equatable {
  let isEnabled: Bool

  var title: String {
    isEnabled ? "Allow Sleep" : "Prevent Sleep"
  }

  var systemImage: String {
    isEnabled ? "cup.and.heat.waves.fill" : "cup.and.heat.waves"
  }

  var helpText: String {
    isEnabled
      ? "Allow system sleep"
      : "Keep the system awake while sessions are active"
  }

  var accessibilityValue: String {
    isEnabled ? "On" : "Off"
  }

  var accessibilityHint: String {
    isEnabled
      ? "Allows the system to sleep again"
      : "Keeps the system awake while sessions are active"
  }
}

struct SleepPreventionToolbarButton: View {
  let store: HarnessMonitorStore
  let presentation: SleepPreventionToolbarPresentation

  var body: some View {
    Button {
      store.sleepPreventionEnabled.toggle()
    } label: {
      Label {
        Text(presentation.title)
      } icon: {
        Image(systemName: presentation.systemImage)
          .frame(
            width: SleepPreventionToolbarSymbolLayout.size,
            height: SleepPreventionToolbarSymbolLayout.size
          )
      }
    }
    .tint(presentation.isEnabled ? .orange : nil)
    .help(presentation.helpText)
    .accessibilityLabel("Sleep prevention")
    .accessibilityValue(presentation.accessibilityValue)
    .accessibilityHint(presentation.accessibilityHint)
    .harnessMCPButton(
      HarnessMonitorAccessibility.sleepPreventionButton,
      label: "Sleep prevention",
      value: presentation.accessibilityValue,
      hint: presentation.accessibilityHint,
      pressAction: { store.sleepPreventionEnabled.toggle() }
    )
  }
}
