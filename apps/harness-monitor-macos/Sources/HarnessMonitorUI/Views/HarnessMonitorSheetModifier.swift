import HarnessMonitorKit
import Observation
import SwiftUI

struct HarnessMonitorSheetModifier: ViewModifier {
  let store: HarnessMonitorStore
  @Bindable var shellUI: HarnessMonitorStore.ContentShellSlice

  func body(content: Content) -> some View {
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
