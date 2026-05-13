import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  var sessionSearchHost: some View {
    AppSearchHost(
      model: stateCache.appSearchModel,
      automation: searchAutomation,
      routeAction: appSearchRouteAction
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
  }
}
