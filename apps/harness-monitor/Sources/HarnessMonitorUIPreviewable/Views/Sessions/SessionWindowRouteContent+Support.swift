import HarnessMonitorKit
import SwiftUI

struct SessionWindowRouteContentMetrics: Equatable {
  let contentPadding: CGFloat
  let overviewSpacing: CGFloat
  let gridHorizontalSpacing: CGFloat
  let gridVerticalSpacing: CGFloat
  let overviewCardMinWidth: CGFloat
  let overviewCardMinHeight: CGFloat
  let overviewCardTextSpacing: CGFloat
  let rowTextSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    contentPadding = 24 * min(scale, 1.3)
    overviewSpacing = 16 * min(scale, 1.35)
    gridHorizontalSpacing = 24 * min(scale, 1.25)
    gridVerticalSpacing = 10 * min(scale, 1.35)
    overviewCardMinWidth = 136 * min(scale, 1.25)
    overviewCardMinHeight = 72 * min(scale, 1.2)
    overviewCardTextSpacing = 6 * min(scale, 1.25)
    rowTextSpacing = 2 * min(scale, 1.45)
  }
}

enum SessionWindowAgentFilter {
  static func filteredAgents(
    _ agents: [AgentRegistration],
    query: String
  ) -> [AgentRegistration] {
    let needle =
      query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !needle.isEmpty else { return agents }
    return agents.filter { agent in
      if agent.name.lowercased().contains(needle) { return true }
      if let personaName = agent.persona?.name.lowercased(), personaName.contains(needle) {
        return true
      }
      if let personaDescription = agent.persona?.description.lowercased(),
        personaDescription.contains(needle)
      {
        return true
      }
      if agent.agentId.lowercased().contains(needle) { return true }
      return false
    }
  }
}
