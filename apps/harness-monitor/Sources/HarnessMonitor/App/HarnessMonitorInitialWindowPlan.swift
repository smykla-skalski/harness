import HarnessMonitorUIPreviewable

struct HarnessMonitorInitialWindowPlan: Equatable {
  enum Destination: Equatable {
    case none
    case dashboard
  }

  let destination: Destination

  static func resolve(
    dashboardRestoreState: Bool?
  ) -> Self {
    switch dashboardRestoreState {
    case true, nil:
      Self(destination: .dashboard)
    case false:
      Self(destination: .none)
    }
  }
}
