import AppKit
import HarnessMonitorKit
import SwiftUI

extension FocusedValues {
  @Entry var harnessPreservePrimaryContentFocus: Bool?
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
