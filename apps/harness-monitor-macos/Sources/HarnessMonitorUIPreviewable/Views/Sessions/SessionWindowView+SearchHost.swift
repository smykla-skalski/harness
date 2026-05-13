import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  var sessionSearchHost: some View {
    AppSearchHost(
      model: stateCache.appSearchModel,
      primaryDomain: stateCache.selection.routeDomain,
      automation: searchAutomation,
      routeAction: appSearchRouteAction
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
  }
}
