import HarnessMonitorKit
import SwiftUI

/// Snapshot of the focused session window's currently active route, used to
/// resolve the cross-domain search "current" scope to a concrete
/// ``AppSearchDomain`` without traversing the view hierarchy.
///
/// `routeID` is the session ID of the publishing window so two session
/// windows that happen to be on the same route do not appear identical to
/// `@FocusedValue` consumers.
public struct HarnessSessionRouteFocus: Equatable, Sendable {
  public let domain: AppSearchDomain
  public let routeID: String

  public init(domain: AppSearchDomain, routeID: String) {
    self.domain = domain
    self.routeID = routeID
  }
}
