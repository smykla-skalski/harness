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
      ? "Allows the system to sleep again."
      : "Keeps the system awake while sessions are active."
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
          .contentTransition(
            .symbolEffect(
              .replace.magic(fallback: .downUp.wholeSymbol),
              options: .nonRepeating
            )
          )
          .frame(
            width: SleepPreventionToolbarSymbolLayout.size,
            height: SleepPreventionToolbarSymbolLayout.size
          )
      }
    }
    .animation(.default, value: presentation.isEnabled)
    .tint(presentation.isEnabled ? .orange : nil)
    .help(presentation.helpText)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
    .accessibilityLabel("Sleep prevention")
    .accessibilityValue(presentation.accessibilityValue)
    .accessibilityHint(presentation.accessibilityHint)
  }
}
