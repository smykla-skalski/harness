import HarnessMonitorKit
import SwiftUI

public struct HarnessInlineActionButton: View {
  public typealias Action = HarnessMonitorActionButton.Action

  public let title: String
  public let actionID: InspectorActionID
  public let store: HarnessMonitorStore
  public let variant: HarnessMonitorAsyncActionButton.Variant
  public let tint: Color?
  public let isExternallyDisabled: Bool
  public let accessibilityIdentifier: String?
  public let help: String
  public let action: Action

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  public init(
    title: String,
    actionID: InspectorActionID,
    store: HarnessMonitorStore,
    variant: HarnessMonitorAsyncActionButton.Variant = .prominent,
    tint: Color? = nil,
    isExternallyDisabled: Bool = false,
    accessibilityIdentifier: String? = nil,
    help: String = "",
    action: @escaping Action
  ) {
    self.title = title
    self.actionID = actionID
    self.store = store
    self.variant = variant
    self.tint = tint
    self.isExternallyDisabled = isExternallyDisabled
    self.accessibilityIdentifier = accessibilityIdentifier
    self.help = help
    self.action = action
  }

  private var isLoading: Bool {
    store.inFlightActionID == actionID.key
  }

  private var isAnotherActionInFlight: Bool {
    store.inFlightActionID != nil && !isLoading
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        if isLoading {
          HarnessMonitorSpinner()
            .transition(.opacity)
        }
        Text(title)
          .lineLimit(1)
      }
      .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
      .animation(
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.2),
        value: isLoading
      )
    }
    .harnessActionButtonStyle(variant: variant, tint: tint)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isExternallyDisabled || isAnotherActionInFlight)
    .help(help)
    .optionalHarnessAccessibilityIdentifier(accessibilityIdentifier)
  }
}

extension View {
  @ViewBuilder
  fileprivate func optionalHarnessAccessibilityIdentifier(_ value: String?) -> some View {
    if let value {
      accessibilityIdentifier(value)
    } else {
      self
    }
  }
}
