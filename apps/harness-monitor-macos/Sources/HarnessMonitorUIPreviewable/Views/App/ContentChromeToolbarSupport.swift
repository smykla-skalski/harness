import HarnessMonitorKit
import SwiftUI

private enum RefreshToolbarFeedbackTiming {
  static let successDuration: Duration = .milliseconds(900)
  static let successTintFadeDuration: Duration = .milliseconds(405)
  static let reduceMotionDuration: Duration = .milliseconds(720)
  static let transitionAnimation: Animation = .smooth(duration: 0.14)
  static let replaceOptions: SymbolEffectOptions = .speed(1.55)
  static let bounceOptions: SymbolEffectOptions = .speed(1.1)
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
  @State private var showsSuccessTint = false
  @State private var successPopToken = 0

  private var displaysSuccessFeedback: Bool {
    (showsSuccessFeedback || showsSuccessTint) && !model.isRefreshing
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
    Button {
      Task { await store.manualRefresh() }
    } label: {
      Label {
        Text("Refresh")
      } icon: {
        toolbarSymbol
      }
    }
    .disabled(model.isRefreshing)
    .help(helpText)
    .accessibilityLabel("Refresh")
    .accessibilityHint("Refresh sessions")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.refreshButton)
    .task(id: model.manualRefreshSuccessToken) {
      guard model.manualRefreshSuccessToken > 0 else {
        return
      }
      if showsSuccessFeedback || showsSuccessTint {
        showsSuccessFeedback = false
        showsSuccessTint = false
        await Task.yield()
      }
      showsSuccessFeedback = true
      showsSuccessTint = true
      guard !reduceMotion else {
        try? await Task.sleep(for: RefreshToolbarFeedbackTiming.reduceMotionDuration)
        guard !Task.isCancelled else {
          showsSuccessFeedback = false
          showsSuccessTint = false
          return
        }
        showsSuccessFeedback = false
        showsSuccessTint = false
        return
      }
      await Task.yield()
      successPopToken += 1
      try? await Task.sleep(for: RefreshToolbarFeedbackTiming.successDuration)
      guard !Task.isCancelled else {
        showsSuccessFeedback = false
        showsSuccessTint = false
        return
      }
      showsSuccessFeedback = false
      try? await Task.sleep(for: RefreshToolbarFeedbackTiming.successTintFadeDuration)
      guard !Task.isCancelled else {
        showsSuccessTint = false
        return
      }
      showsSuccessTint = false
    }
  }

  @ViewBuilder
  private var toolbarSymbol: some View {
    if shouldSpin {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
        toolbarSymbolImage(rotationDegrees: rotationDegrees(at: context.date))
      }
    } else {
      toolbarSymbolImage(rotationDegrees: 0)
    }
  }

  private func toolbarSymbolImage(rotationDegrees: Double) -> some View {
    Image(systemName: showsSuccessFeedback ? "checkmark" : "arrow.clockwise")
      .foregroundStyle(.primary)
      .rotationEffect(.degrees(showsSuccessFeedback ? 0 : rotationDegrees))
      .contentTransition(
        .symbolEffect(.replace, options: RefreshToolbarFeedbackTiming.replaceOptions)
      )
      .overlay {
        if showsSuccessTint {
          Image(systemName: "checkmark")
            .foregroundStyle(.green)
            .symbolEffect(
              .bounce,
              options: RefreshToolbarFeedbackTiming.bounceOptions,
              value: successPopToken
            )
            .blendMode(.sourceAtop)
            .accessibilityHidden(true)
        }
      }
      .compositingGroup()
      .animation(
        reduceMotion ? nil : RefreshToolbarFeedbackTiming.transitionAnimation,
        value: showsSuccessFeedback
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
