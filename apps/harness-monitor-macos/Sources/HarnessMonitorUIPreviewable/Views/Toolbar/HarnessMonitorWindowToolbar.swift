import SwiftUI

struct HarnessMonitorWindowToolbar<
  NavigationItems: ToolbarContent,
  AutomaticItems: ToolbarContent,
  PrimaryActionItems: ToolbarContent
>: ToolbarContent {
  private let navigationItems: NavigationItems
  private let automaticItems: AutomaticItems
  private let primaryActionItems: PrimaryActionItems

  init(
    @ToolbarContentBuilder navigation: () -> NavigationItems,
    @ToolbarContentBuilder automatic: () -> AutomaticItems,
    @ToolbarContentBuilder primaryAction: () -> PrimaryActionItems
  ) {
    navigationItems = navigation()
    automaticItems = automatic()
    primaryActionItems = primaryAction()
  }

  @ToolbarContentBuilder var body: some ToolbarContent {
    navigationItems
    automaticItems
    primaryActionItems
  }
}
