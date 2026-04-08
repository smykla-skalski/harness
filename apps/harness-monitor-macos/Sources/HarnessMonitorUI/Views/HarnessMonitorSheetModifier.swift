import HarnessMonitorKit
import SwiftUI

struct HarnessMonitorSheetModifier: ViewModifier {
  @Bindable var store: HarnessMonitorStore

  func body(content: Content) -> some View {
    content
      .sheet(item: $store.presentedSheet) { sheet in
        HarnessMonitorSheetRouter(store: store, sheet: sheet)
      }
  }
}
