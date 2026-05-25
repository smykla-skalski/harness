import AppIntents

public struct HarnessMonitorAppShortcuts: AppShortcutsProvider {
  public static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: GetNeedsMeCountIntent(),
      phrases: [
        "How many pull requests need me in \(.applicationName)",
        "\(.applicationName) needs-me count",
        "Pull requests waiting for me in \(.applicationName)",
      ],
      shortTitle: "Needs-Me Count",
      systemImageName: "checklist.checked"
    )

    AppShortcut(
      intent: OpenReviewsNeedsMeIntent(),
      phrases: [
        "Open my review queue in \(.applicationName)",
        "Show reviews waiting in \(.applicationName)",
        "Open \(.applicationName) reviews",
      ],
      shortTitle: "Open Reviews",
      systemImageName: "list.bullet.rectangle"
    )

    AppShortcut(
      intent: OpenPullRequestIntent(),
      phrases: [
        "Open \(\.$target) in \(.applicationName)",
        "Show \(\.$target) in \(.applicationName)",
        "Bring up \(\.$target) in \(.applicationName)",
      ],
      shortTitle: "Open Pull Request",
      systemImageName: "arrow.up.right.square"
    )

    AppShortcut(
      intent: ApprovePullRequestIntent(),
      phrases: [
        "Approve \(\.$pullRequest) in \(.applicationName)",
        "LGTM \(\.$pullRequest) in \(.applicationName)",
        "Sign off on \(\.$pullRequest) in \(.applicationName)",
      ],
      shortTitle: "Approve Pull Request",
      systemImageName: "checkmark.seal"
    )

    AppShortcut(
      intent: MergePullRequestIntent(),
      phrases: [
        "Merge \(\.$pullRequest) in \(.applicationName)",
        "Land \(\.$pullRequest) in \(.applicationName)",
        "Ship \(\.$pullRequest) in \(.applicationName)",
      ],
      shortTitle: "Merge Pull Request",
      systemImageName: "arrow.triangle.merge"
    )

    AppShortcut(
      intent: RerunChecksIntent(),
      phrases: [
        "Rerun checks for \(\.$pullRequest) in \(.applicationName)",
        "Retry CI on \(\.$pullRequest) in \(.applicationName)",
        "Restart checks on \(\.$pullRequest) in \(.applicationName)",
      ],
      shortTitle: "Rerun Checks",
      systemImageName: "arrow.clockwise.circle"
    )

    AppShortcut(
      intent: RefreshRepositoryIntent(),
      phrases: [
        "Refresh \(\.$repository) in \(.applicationName)",
        "Sync \(\.$repository) in \(.applicationName)",
        "Pull updates for \(\.$repository) in \(.applicationName)",
      ],
      shortTitle: "Refresh Repository",
      systemImageName: "arrow.clockwise"
    )

    AppShortcut(
      intent: RefreshAllReposIntent(),
      phrases: [
        "Refresh all repositories in \(.applicationName)",
        "Sync everything in \(.applicationName)",
        "Pull updates in \(.applicationName)",
      ],
      shortTitle: "Refresh All",
      systemImageName: "arrow.clockwise.square"
    )

    AppShortcut(
      intent: OpenTaskBoardIntent(),
      phrases: [
        "Open the task board in \(.applicationName)",
        "Show tasks in \(.applicationName)",
        "Open \(.applicationName) tasks",
      ],
      shortTitle: "Open Task Board",
      systemImageName: "square.grid.3x3"
    )

    AppShortcut(
      intent: ListTaskBoardItemsIntent(),
      phrases: [
        "List my tasks in \(.applicationName)",
        "What is on the \(.applicationName) board",
        "Show \(.applicationName) tasks",
      ],
      shortTitle: "List Tasks",
      systemImageName: "list.bullet"
    )
  }

  /// Renderable snapshot of every AppShortcut phrase, keyed by short
  /// title. Placeholder tokens use `${appName}` for `\(.applicationName)`,
  /// `${target}` for the OpenIntent target, `${pullRequest}` for the
  /// pull-request parameter, and `${repository}` for the repository
  /// parameter. Updating a phrase above without updating this snapshot
  /// fails `testAppShortcutPhrasesMatchSnapshot`, which catches silent
  /// renames that would break user-saved shortcuts and memorised Siri
  /// invocations
  public static func appShortcutPhraseSnapshot() -> [String: [String]] {
    [
      "Needs-Me Count": [
        "How many pull requests need me in ${appName}",
        "${appName} needs-me count",
        "Pull requests waiting for me in ${appName}",
      ],
      "Open Reviews": [
        "Open my review queue in ${appName}",
        "Show reviews waiting in ${appName}",
        "Open ${appName} reviews",
      ],
      "Open Pull Request": [
        "Open ${target} in ${appName}",
        "Show ${target} in ${appName}",
        "Bring up ${target} in ${appName}",
      ],
      "Approve Pull Request": [
        "Approve ${pullRequest} in ${appName}",
        "LGTM ${pullRequest} in ${appName}",
        "Sign off on ${pullRequest} in ${appName}",
      ],
      "Merge Pull Request": [
        "Merge ${pullRequest} in ${appName}",
        "Land ${pullRequest} in ${appName}",
        "Ship ${pullRequest} in ${appName}",
      ],
      "Rerun Checks": [
        "Rerun checks for ${pullRequest} in ${appName}",
        "Retry CI on ${pullRequest} in ${appName}",
        "Restart checks on ${pullRequest} in ${appName}",
      ],
      "Refresh Repository": [
        "Refresh ${repository} in ${appName}",
        "Sync ${repository} in ${appName}",
        "Pull updates for ${repository} in ${appName}",
      ],
      "Refresh All": [
        "Refresh all repositories in ${appName}",
        "Sync everything in ${appName}",
        "Pull updates in ${appName}",
      ],
      "Open Task Board": [
        "Open the task board in ${appName}",
        "Show tasks in ${appName}",
        "Open ${appName} tasks",
      ],
      "List Tasks": [
        "List my tasks in ${appName}",
        "What is on the ${appName} board",
        "Show ${appName} tasks",
      ],
    ]
  }
}
