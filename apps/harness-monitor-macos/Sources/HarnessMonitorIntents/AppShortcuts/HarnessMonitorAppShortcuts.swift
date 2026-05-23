import AppIntents

public struct HarnessMonitorAppShortcuts: AppShortcutsProvider {
  public static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: GetNeedsMeCountIntent(),
      phrases: [
        "How many pull requests need me in \(.applicationName)",
        "\(.applicationName) needs-me count",
        "Pull requests waiting for me in \(.applicationName)"
      ],
      shortTitle: "Needs-Me Count",
      systemImageName: "checklist.checked"
    )

    AppShortcut(
      intent: OpenReviewsNeedsMeIntent(),
      phrases: [
        "Open my review queue in \(.applicationName)",
        "Show reviews waiting in \(.applicationName)",
        "Open \(.applicationName) reviews"
      ],
      shortTitle: "Open Reviews",
      systemImageName: "list.bullet.rectangle"
    )

    AppShortcut(
      intent: OpenPullRequestIntent(),
      phrases: [
        "Open \(\.$pullRequest) in \(.applicationName)",
        "Show \(\.$pullRequest) in \(.applicationName)",
        "Bring up \(\.$pullRequest) in \(.applicationName)"
      ],
      shortTitle: "Open Pull Request",
      systemImageName: "arrow.up.right.square"
    )

    AppShortcut(
      intent: RefreshRepositoryIntent(),
      phrases: [
        "Refresh \(\.$repository) in \(.applicationName)",
        "Sync \(\.$repository) in \(.applicationName)",
        "Pull updates for \(\.$repository) in \(.applicationName)"
      ],
      shortTitle: "Refresh Repository",
      systemImageName: "arrow.clockwise"
    )

    AppShortcut(
      intent: OpenTaskBoardIntent(),
      phrases: [
        "Open the task board in \(.applicationName)",
        "Show tasks in \(.applicationName)",
        "Open \(.applicationName) tasks"
      ],
      shortTitle: "Open Task Board",
      systemImageName: "square.grid.3x3"
    )

    AppShortcut(
      intent: ListTaskBoardItemsIntent(),
      phrases: [
        "List my tasks in \(.applicationName)",
        "What is on the \(.applicationName) board",
        "Show \(.applicationName) tasks"
      ],
      shortTitle: "List Tasks",
      systemImageName: "list.bullet"
    )
  }
}
