import HarnessMonitorKit
import SwiftUI

struct ContentNavigationToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        Task { await store.navigateBack() }
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(!model.canNavigateBack)
      .help("Go back")
      .accessibilityIdentifier(HarnessMonitorAccessibility.navigateBackButton)

      Button {
        Task { await store.navigateForward() }
      } label: {
        Label("Forward", systemImage: "chevron.forward")
      }
      .disabled(!model.canNavigateForward)
      .help("Go forward")
      .accessibilityIdentifier(HarnessMonitorAccessibility.navigateForwardButton)
    }
  }
}

struct RefreshToolbarButton: View {
  let isRefreshing: Bool
  let refresh: () -> Void
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isSpinning = false

  var body: some View {
    Button(action: refresh) {
      Label {
        Text("Refresh")
      } icon: {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(.degrees(reduceMotion ? 0 : (isSpinning ? 360 : 0)))
          .animation(
            reduceMotion
              ? nil
              : isSpinning
                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                : .easeOut(duration: 0.4),
            value: isSpinning
          )
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.refreshButton)
    .onChange(of: isRefreshing) { _, refreshing in
      isSpinning = refreshing
    }
  }
}
