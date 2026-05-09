enum SessionWindowRouteLayoutStyle {
  case sidebarDetail
  case sidebarContentDetail
}

extension SessionWindowRoute {
  var layoutStyle: SessionWindowRouteLayoutStyle {
    switch self {
    case .overview, .timeline:
      .sidebarDetail
    case .agents, .tasks, .decisions, .terminal:
      .sidebarContentDetail
    }
  }
}
