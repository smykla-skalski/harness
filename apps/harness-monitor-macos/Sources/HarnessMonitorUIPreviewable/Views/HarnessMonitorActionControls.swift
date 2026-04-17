import SwiftUI

struct HarnessMonitorActionButton: View {
  typealias Action = @MainActor @Sendable () -> Void
  typealias Variant = HarnessMonitorAsyncActionButton.Variant

  let title: String
  let tint: Color?
  let variant: Variant
  let accessibilityIdentifier: String
  let fillsWidth: Bool
  let action: Action

  init(
    title: String,
    tint: Color? = nil,
    variant: Variant,
    accessibilityIdentifier: String,
    fillsWidth: Bool = false,
    action: @escaping Action
  ) {
    self.title = title
    self.tint = tint
    self.variant = variant
    self.accessibilityIdentifier = accessibilityIdentifier
    self.fillsWidth = fillsWidth
    self.action = action
  }

  var body: some View {
    Button {
      action()
    } label: {
      ProminentAwareLabel {
        Text(title)
          .lineLimit(1)
          .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
          .frame(maxWidth: fillsWidth ? .infinity : nil)
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil)
    .harnessActionButtonStyle(variant: variant, tint: tint)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityFrameMarker("\(accessibilityIdentifier).frame")
  }
}

struct HarnessMonitorAsyncActionButton: View {
  typealias Action = @MainActor @Sendable () async -> Void

  enum Variant: Equatable {
    case prominent
    case bordered
    case borderless
  }

  let title: String
  let tint: Color?
  let variant: Variant
  let isLoading: Bool
  let accessibilityIdentifier: String
  let fillsWidth: Bool
  let action: Action
  @State private var runningTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  init(
    title: String,
    tint: Color? = nil,
    variant: Variant,
    isLoading: Bool,
    accessibilityIdentifier: String,
    fillsWidth: Bool = false,
    action: @escaping Action
  ) {
    self.title = title
    self.tint = tint
    self.variant = variant
    self.isLoading = isLoading
    self.accessibilityIdentifier = accessibilityIdentifier
    self.fillsWidth = fillsWidth
    self.action = action
  }

  private var effectiveVariant: Variant {
    isLoading ? .bordered : variant
  }

  private var effectiveTint: Color? {
    isLoading ? .secondary : tint
  }

  var body: some View {
    Button {
      if isLoading {
        cancelAction()
      } else {
        performAction()
      }
    } label: {
      label
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil)
    .harnessActionButtonStyle(variant: effectiveVariant, tint: effectiveTint)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityFrameMarker("\(accessibilityIdentifier).frame")
    .onDisappear {
      runningTask?.cancel()
      runningTask = nil
    }
  }

  private var label: some View {
    ProminentAwareLabel {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        if isLoading {
          HarnessMonitorSpinner()
            .transition(.opacity)
        }
        Text(isLoading ? "Cancel" : title)
          .lineLimit(1)
      }
      .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
      .frame(maxWidth: fillsWidth ? .infinity : nil)
      .animation(reduceMotion ? nil : .spring(duration: 0.2), value: isLoading)
    }
  }

  private func performAction() {
    let action = action
    runningTask = Task { @MainActor in
      await action()
      runningTask = nil
    }
  }

  private func cancelAction() {
    runningTask?.cancel()
    runningTask = nil
  }
}

private struct ProminentAwareLabel<Content: View>: View {
  @Environment(\.prominentButtonForeground)
  private var prominentForeground
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    if let prominentForeground {
      content.foregroundStyle(prominentForeground)
    } else {
      content
    }
  }
}
