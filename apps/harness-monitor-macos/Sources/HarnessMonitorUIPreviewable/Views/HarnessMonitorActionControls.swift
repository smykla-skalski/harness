import AppKit
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
    ZStack {
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
    }
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
  public let action: Action
  @State private var runningTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  public init(
    title: String,
    tint: Color? = nil,
    variant: Variant,
    role: ButtonRole? = nil,
    isLoading: Bool,
    accessibilityIdentifier: String,
    fillsWidth: Bool = false,
    action: @escaping Action
  ) {
    self.title = title
    self.tint = tint
    self.variant = variant
    self.role = role
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

  public var body: some View {
    ZStack {
      Button(role: role) {
        if isLoading {
          cancelAction()
        } else {
          performAction()
        }
      } label: {
        label
      }
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

struct CommandReturnKeyMonitor: NSViewRepresentable {
  let isEnabled: Bool
  let action: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.installMonitorIfNeeded()
    let view = NSView()
    view.alphaValue = 0
    view.setAccessibilityHidden(true)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.isEnabled = isEnabled
    context.coordinator.action = action
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeMonitor()
  }

  final class Coordinator {
    var isEnabled = false
    var action: () -> Void = {}
    private var monitor: Any?

    deinit {
      removeMonitor()
    }

    func installMonitorIfNeeded() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        guard self.isEnabled, Self.isCommandReturn(event) else { return event }
        self.action()
        return nil
      }
    }

    func removeMonitor() {
      guard let monitor else { return }
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }

    private static func isCommandReturn(_ event: NSEvent) -> Bool {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard modifiers == .command else { return false }
      return event.keyCode == 36 || event.keyCode == 76
    }
  }
}
