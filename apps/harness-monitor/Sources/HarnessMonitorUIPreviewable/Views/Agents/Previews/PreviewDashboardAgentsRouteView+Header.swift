import SwiftUI

extension DashboardAgentsPreviewRenderer {
  @MainActor
  static func renderHeaderStates(textSizeIndex: Int, directory: String) -> Bool {
    renderHeader(
      name: "agents-header-compact",
      width: 700,
      textSizeIndex: textSizeIndex,
      directory: directory
    )
      && renderHeader(
        name: "agents-header-icons",
        width: 440,
        textSizeIndex: textSizeIndex,
        directory: directory
      )
  }

  @MainActor
  private static func renderHeader(
    name: String,
    width: CGFloat,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    renderSheet(name: name, textSizeIndex: textSizeIndex, directory: directory) {
      DashboardAgentsRouteHeader(
        countText: "3 agents across 2 workspaces",
        sourceLabel: "Live",
        isLoading: false,
        canCreateAgent: true,
        createTerminalAgent: {},
        createCodexAgent: {},
        createAcpAgent: {},
        refresh: {}
      )
      .frame(width: width)
      .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
  }
}
