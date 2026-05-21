import HarnessMonitorKit
import SwiftUI

extension View {
  /// Attach the unified session-window search to a view's body.
  public func appSearchHost(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    primaryDomainProvider: @escaping @MainActor () -> AppSearchDomain? = { nil },
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    isEnabled: Bool = true,
    automation: AppSearchAutomationState? = nil,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) -> some View {
    modifier(
      AppSearchHostModifier(
        model: model,
        prompt: prompt,
        primaryDomainProvider: primaryDomainProvider,
        fallbackPrimaryDomain: fallbackPrimaryDomain,
        isEnabled: isEnabled,
        automation: automation,
        routeAction: routeAction
      )
    )
  }
}
