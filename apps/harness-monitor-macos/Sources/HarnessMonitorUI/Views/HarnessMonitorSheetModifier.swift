import HarnessMonitorKit
import SwiftUI

struct HarnessMonitorSheetModifier: ViewModifier {
  let store: HarnessMonitorStore
  let presentedSheet: HarnessMonitorStore.PresentedSheet?

  func body(content: Content) -> some View {
    content
      .sheet(
        item: Binding(
          get: { presentedSheet },
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
