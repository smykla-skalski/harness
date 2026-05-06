import HarnessMonitorKit
import SwiftUI

extension View {
  @ViewBuilder
  func harnessPrimaryContentScrollSurface(
    listIdentifier: String? = nil,
    listLabel: String? = nil
  ) -> some View {
    let targetView = self
    if let listIdentifier {
      targetView.harnessMCPList(
        listIdentifier,
        label: listLabel ?? listIdentifier
      )
    } else {
      targetView
    }
  }
}
