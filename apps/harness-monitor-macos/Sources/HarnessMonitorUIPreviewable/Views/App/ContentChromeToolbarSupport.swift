import HarnessMonitorKit
import SwiftUI

private enum RefreshToolbarFeedbackTiming {
  static let successDuration: Duration = .milliseconds(400)
  static let reduceMotionDuration: Duration = .milliseconds(320)
  static let transitionAnimation: Animation = .smooth(duration: 0.28)
  static let bounceOptions: SymbolEffectOptions = .speed(0.8)
}

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
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var showsSuccessFeedback = false
  @State private var successPopToken = 0

  private var displaysSuccessFeedback: Bool {
    showsSuccessFeedback && !model.isRefreshing
  }

  private var helpText: String {
    if model.isRefreshing {
      "Refreshing sessions"
    } else if displaysSuccessFeedback {
      "Refresh complete"
    } else {
      "Refresh sessions"
    }
  }

  private var accessibilityValue: String {
    if model.isRefreshing {
      "Refreshing"
    } else if displaysSuccessFeedback {
      "Completed"
    } else {
      ""
    }
  }

  private var shouldSpin: Bool {
    model.isRefreshing && !reduceMotion && !displaysSuccessFeedback
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldSpin)) { context in
      Button {
        Task { await store.manualRefresh() }
      } label: {
        Label {
          Text("Refresh")
        } icon: {
          toolbarSymbol(at: context.date)
        }
      }
      .disabled(model.isRefreshing)
      .help(helpText)
      .accessibilityLabel("Refresh")
      .accessibilityHint("Refresh sessions")
      .accessibilityValue(accessibilityValue)
      .accessibilityIdentifier(HarnessMonitorAccessibility.refreshButton)
    }
    .task(id: model.manualRefreshSuccessToken) {
      guard model.manualRefreshSuccessToken > 0 else {
        return
      }
      if showsSuccessFeedback {
        showsSuccessFeedback = false
        await Task.yield()
      }
      showsSuccessFeedback = true
      guard !reduceMotion else {
        try? await Task.sleep(for: RefreshToolbarFeedbackTiming.reduceMotionDuration)
        guard !Task.isCancelled else {
          return
        }
        showsSuccessFeedback = false
        return
      }
      await Task.yield()
      successPopToken += 1
      try? await Task.sleep(for: RefreshToolbarFeedbackTiming.successDuration)
      guard !Task.isCancelled else {
        return
      }
      showsSuccessFeedback = false
    }
  }

  private func toolbarSymbol(at date: Date) -> some View {
    Image(systemName: displaysSuccessFeedback ? "checkmark" : "arrow.clockwise")
      .foregroundStyle(displaysSuccessFeedback ? Color.green : Color.primary)
      .rotationEffect(.degrees(displaysSuccessFeedback ? 0 : rotationDegrees(at: date)))
      .contentTransition(.symbolEffect(.replace))
      .symbolEffect(
        .bounce,
        options: RefreshToolbarFeedbackTiming.bounceOptions,
        value: successPopToken
      )
      .animation(
        reduceMotion ? nil : RefreshToolbarFeedbackTiming.transitionAnimation,
        value: displaysSuccessFeedback
      )
      .frame(width: 14, height: 14)
      .accessibilityHidden(true)
  }

  private func rotationDegrees(at date: Date) -> Double {
    guard shouldSpin else {
      return 0
    }
    let cyclePosition = (date.timeIntervalSinceReferenceDate / 0.9)
      .truncatingRemainder(dividingBy: 1)
    return cyclePosition * 360
  }
}
