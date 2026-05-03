import AppKit
import HarnessMonitorKit
import SwiftUI

extension FocusedValues {
  @Entry var harnessPreservePrimaryContentFocus: Bool?
  @Entry public var harnessPrimaryContentResetSuppression: PrimaryContentResetSuppression?
}

public struct PrimaryContentResetSuppression: Equatable {
  public let preservesPrimaryContentFocus: Bool
  public let hasFocusedEditorField: Bool
  public let hasPresentedSheet: Bool
  public let hasPendingConfirmation: Bool
  public let extraSuppressor: Bool

  public init(
    preservesPrimaryContentFocus: Bool,
    hasFocusedEditorField: Bool = false,
    hasPresentedSheet: Bool,
    hasPendingConfirmation: Bool,
    extraSuppressor: Bool = false
  ) {
    self.preservesPrimaryContentFocus = preservesPrimaryContentFocus
    self.hasFocusedEditorField = hasFocusedEditorField
    self.hasPresentedSheet = hasPresentedSheet
    self.hasPendingConfirmation = hasPendingConfirmation
    self.extraSuppressor = extraSuppressor
  }

  public var isSuppressed: Bool {
    if preservesPrimaryContentFocus { return true }
    if hasFocusedEditorField { return true }
    if hasPresentedSheet { return true }
    if hasPendingConfirmation { return true }
    return extraSuppressor
  }
}

extension View {
  @ViewBuilder
  func harnessPrimaryContentFocusTarget(
    focusScope: Namespace.ID? = nil,
    prefersDefaultFocus: Bool = false,
    pagingResponderRequest: Int = 0,
    listIdentifier: String? = nil,
    listLabel: String? = nil
  ) -> some View {
    let targetView = self.harnessPrimaryContentPagingResponder(
      request: pagingResponderRequest,
      isEnabled: prefersDefaultFocus
    )
    if let focusScope {
      let focusedTarget =
        targetView
        .focusable()
        .prefersDefaultFocus(prefersDefaultFocus, in: focusScope)
      if let listIdentifier {
        focusedTarget.harnessMCPList(
          listIdentifier,
          label: listLabel ?? listIdentifier
        )
      } else {
        focusedTarget
      }
    } else if let listIdentifier {
      targetView.harnessMCPList(
        listIdentifier,
        label: listLabel ?? listIdentifier
      )
    } else {
      targetView
    }
  }

  func harnessPreservePrimaryContentFocus(_ isPreserved: Bool = true) -> some View {
    focusedSceneValue(\.harnessPreservePrimaryContentFocus, isPreserved)
  }

  func harnessPrimaryContentPagingResponder(
    request: Int,
    isEnabled: Bool = true
  ) -> some View {
    background(
      PrimaryContentPagingResponderBridge(
        request: request,
        isEnabled: isEnabled
      )
    )
  }
}

private struct PrimaryContentPagingResponderBridge: NSViewRepresentable {
  let request: Int
  let isEnabled: Bool

  func makeNSView(context _: Context) -> PrimaryContentPagingResponderBridgeView {
    let view = PrimaryContentPagingResponderBridgeView()
    view.alphaValue = 0
    view.setAccessibilityHidden(true)
    return view
  }

  func updateNSView(_ nsView: PrimaryContentPagingResponderBridgeView, context _: Context) {
    nsView.update(request: request, isEnabled: isEnabled)
  }
}
