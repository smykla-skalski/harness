import HarnessMonitorKit
import SwiftUI

public struct HarnessMonitorSheetModifier: ViewModifier {
  public let store: HarnessMonitorStore
  public let shellUI: HarnessMonitorStore.ContentShellSlice
  public let isEnabled: Bool

  public init(
    store: HarnessMonitorStore,
    shellUI: HarnessMonitorStore.ContentShellSlice,
    isEnabled: Bool = true
  ) {
    self.store = store
    self.shellUI = shellUI
    self.isEnabled = isEnabled
  }

  @ViewBuilder
  public func body(content: Content) -> some View {
    if isEnabled {
      content
        .sheet(
          item: Binding(
            get: { shellUI.presentedSheet },
            set: { sheet in
              if sheet == nil {
                store.dismissSheet()
              }
            }
          )
        ) { sheet in
          HarnessMonitorSheetRouter(store: store, sheet: sheet)
        }
    } else {
      content
    }
  }
}
