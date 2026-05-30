import AppIntents
import XCTest

@testable import HarnessMonitorIntents

final class HarnessMonitorAppShortcutsTests: XCTestCase {
  func testAppShortcutsExposesAllSpotlightSurfacedIntents() {
    let shortcuts = HarnessMonitorAppShortcuts.appShortcuts

    XCTAssertEqual(
      shortcuts.count,
      10,
      "AppShortcutsProvider count is a contract - adding or removing a shortcut "
        + "changes how Spotlight surfaces Harness Monitor"
    )
  }

  func testAppShortcutsStayAtOrBelowAppleSoftLimit() {
    let shortcuts = HarnessMonitorAppShortcuts.appShortcuts

    XCTAssertLessThanOrEqual(
      shortcuts.count,
      10,
      "Apple's documented soft limit for AppShortcutsProvider is 10 - extra shortcuts "
        + "may not surface in Spotlight"
    )
  }

  /// Phrase strings are the voice + Spotlight surface contract. A silent
  /// rename breaks every user-saved shortcut and every memorised Siri
  /// invocation. This snapshot pins the exact phrasing per shortcut so a
  /// rename has to be intentional
  func testAppShortcutPhrasesMatchSnapshot() {
    let observed = HarnessMonitorAppShortcuts.appShortcutPhraseSnapshot()
    let expected: [String: [String]] = [
      "Needs-Me Count": [
        "How many pull requests need me in ${appName}",
        "${appName} needs-me count",
        "Pull requests waiting for me in ${appName}"
      ],
      "Open Reviews": [
        "Open my review queue in ${appName}",
        "Show reviews waiting in ${appName}",
        "Open ${appName} reviews"
      ],
      "Open Pull Request": [
        "Open ${target} in ${appName}",
        "Show ${target} in ${appName}",
        "Bring up ${target} in ${appName}"
      ],
      "Approve Pull Request": [
        "Approve ${pullRequest} in ${appName}",
        "LGTM ${pullRequest} in ${appName}",
        "Sign off on ${pullRequest} in ${appName}"
      ],
      "Merge Pull Request": [
        "Merge ${pullRequest} in ${appName}",
        "Land ${pullRequest} in ${appName}",
        "Ship ${pullRequest} in ${appName}"
      ],
      "Rerun Checks": [
        "Rerun checks for ${pullRequest} in ${appName}",
        "Retry CI on ${pullRequest} in ${appName}",
        "Restart checks on ${pullRequest} in ${appName}"
      ],
      "Refresh Repository": [
        "Refresh ${repository} in ${appName}",
        "Sync ${repository} in ${appName}",
        "Pull updates for ${repository} in ${appName}"
      ],
      "Refresh All": [
        "Refresh all repositories in ${appName}",
        "Sync everything in ${appName}",
        "Pull updates in ${appName}"
      ],
      "Open Task Board": [
        "Open the task board in ${appName}",
        "Show tasks in ${appName}",
        "Open ${appName} tasks"
      ],
      "List Tasks": [
        "List my tasks in ${appName}",
        "What is on the ${appName} board",
        "Show ${appName} tasks"
      ]
    ]

    XCTAssertEqual(
      observed.keys.sorted(),
      expected.keys.sorted(),
      "shortTitle set drifted from snapshot"
    )
    for (title, phrases) in expected {
      XCTAssertEqual(
        observed[title],
        phrases,
        "phrases for \(title) drifted from snapshot"
      )
    }
  }
}
