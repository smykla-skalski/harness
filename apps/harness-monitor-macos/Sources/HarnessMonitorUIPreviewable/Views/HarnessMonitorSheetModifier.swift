import HarnessMonitorKit
import SwiftUI

public struct HarnessMonitorSheetModifier: ViewModifier {
  public let store: HarnessMonitorStore
  public let shellUI: HarnessMonitorStore.ContentShellSlice

  public init(store: HarnessMonitorStore, shellUI: HarnessMonitorStore.ContentShellSlice) {
    self.store = store
    self.shellUI = shellUI
  }

  public func body(content: Content) -> some View {
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
  }
}
