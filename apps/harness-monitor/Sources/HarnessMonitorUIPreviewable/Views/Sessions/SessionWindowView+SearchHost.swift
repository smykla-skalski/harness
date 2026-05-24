import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  var sessionSearchHost: some View {
    AppSearchHost(
      model: stateCache.appSearchModel,
      primaryDomainProvider: { stateCache.selection.routeDomain },
      isEnabled: isStartupSearchParticipationEnabled,
      automation: searchAutomation,
      routeAction: appSearchRouteAction
    )
  }
}
