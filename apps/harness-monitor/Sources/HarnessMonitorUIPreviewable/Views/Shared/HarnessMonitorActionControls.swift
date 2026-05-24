import HarnessMonitorKit
import SwiftUI

public struct HarnessMonitorActionButton: View {
  public typealias Action = @MainActor @Sendable () -> Void
  public typealias Variant = HarnessMonitorAsyncActionButton.Variant

  public let title: String
  public let tint: Color?
  public let variant: Variant
  public let accessibilityIdentifier: String
  public let fillsWidth: Bool
  public let action: Action
  @Environment(\.isEnabled)
  private var isEnabled

  public init(
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

  public var body: some View {
    Button {
      action()
    } label: {
      ProminentAwareLabel {
        Text(title)
          .lineLimit(1)
          .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
          .frame(maxWidth: fillsWidth ? .infinity : nil)
      }
      .contentShape(Rectangle())
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil)
    .harnessActionButtonStyle(variant: variant, tint: tint)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .harnessMCPButton(
      accessibilityIdentifier,
      label: title,
      enabled: isEnabled,
      pressAction: action
    )
    .accessibilityFrameMarker("\(accessibilityIdentifier).frame")
  }
}

public struct HarnessMonitorAsyncActionButton: View {
  public typealias Action = @MainActor @Sendable () async -> Void

  public enum Variant: Equatable {
    case prominent
    case bordered
    case borderless
  }

  public let title: String
  public let tint: Color?
  public let variant: Variant
  public let role: ButtonRole?
  public let isLoading: Bool
  public let accessibilityIdentifier: String
  public let fillsWidth: Bool
  private let accessibilityFocusBinding: AccessibilityFocusState<String?>.Binding?
  private let accessibilityFocusValue: String?
  private let keyboardFocusBinding: FocusState<String?>.Binding?
  private let keyboardFocusValue: String?
  public let action: Action
  @State private var runningTask: Task<Void, Never>?
  @Environment(\.isEnabled)
  private var isEnabled

  public init(
    title: String,
    tint: Color? = nil,
    variant: Variant,
    role: ButtonRole? = nil,
    isLoading: Bool,
    accessibilityIdentifier: String,
    fillsWidth: Bool = false,
    accessibilityFocusBinding: AccessibilityFocusState<String?>.Binding? = nil,
    accessibilityFocusValue: String? = nil,
    keyboardFocusBinding: FocusState<String?>.Binding? = nil,
    keyboardFocusValue: String? = nil,
    action: @escaping Action
  ) {
    self.title = title
    self.tint = tint
    self.variant = variant
    self.role = role
    self.isLoading = isLoading
    self.accessibilityIdentifier = accessibilityIdentifier
    self.fillsWidth = fillsWidth
    self.accessibilityFocusBinding = accessibilityFocusBinding
    self.accessibilityFocusValue = accessibilityFocusValue
    self.keyboardFocusBinding = keyboardFocusBinding
    self.keyboardFocusValue = keyboardFocusValue
    self.action = action
  }

  private var effectiveVariant: Variant {
    isLoading ? .bordered : variant
  }

  private var effectiveTint: Color? {
    isLoading ? .secondary : tint
  }

  public var body: some View {
    let control = Button(role: role) {
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
    .harnessMCPButton(
      accessibilityIdentifier,
      label: isLoading ? "Cancel" : title,
      enabled: isEnabled,
      pressAction: {
        if isLoading {
          cancelAction()
        } else {
          performAction()
        }
      }
    )
    .accessibilityFrameMarker("\(accessibilityIdentifier).frame")
    .onDisappear {
      runningTask?.cancel()
      runningTask = nil
    }

    if let keyboardFocusBinding, let keyboardFocusValue {
      let keyboardFocusedControl = control.focused(
        keyboardFocusBinding,
        equals: keyboardFocusValue
      )
      if let accessibilityFocusBinding, let accessibilityFocusValue {
        keyboardFocusedControl.accessibilityFocused(
          accessibilityFocusBinding,
          equals: accessibilityFocusValue
        )
      } else {
        keyboardFocusedControl
      }
    } else if let accessibilityFocusBinding, let accessibilityFocusValue {
      control.accessibilityFocused(accessibilityFocusBinding, equals: accessibilityFocusValue)
    } else {
      control
    }
  }

  private var label: some View {
    ProminentAwareLabel {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        if isLoading {
          HarnessMonitorSpinner()
        }
        Text(isLoading ? "Cancel" : title)
          .lineLimit(1)
      }
      .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
      .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
    .contentShape(Rectangle())
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
