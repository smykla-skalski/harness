import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  @ViewBuilder var routeDetailColumn: some View {
    trackpadHistoryContentColumn
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder var trackpadHistoryContentColumn: some View {
    contentColumn
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .harnessTrackpadHistorySwipe(
        navigation: windowNavigationState,
        isEnabled: trackpadNavigationEnabled && renderedRoute.supportsTrackpadHistorySwipe
      )
  }
}
