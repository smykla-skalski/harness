import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board card preferences")
@MainActor
struct TaskBoardCardPreferencesTests {
  @Test("Global priority badge preference persists through UserDefaults")
  func globalPriorityBadgePreferencePersistsThroughUserDefaults() throws {
    let suiteName = "TaskBoardCardPreferencesTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    #expect(TaskBoardCardPreferences.showsPriorityBadge(from: userDefaults))

    TaskBoardCardPreferences.setShowsPriorityBadge(false, in: userDefaults)
    userDefaults.synchronize()

    let restartedDefaults = try #require(UserDefaults(suiteName: suiteName))
    #expect(!TaskBoardCardPreferences.showsPriorityBadge(from: restartedDefaults))
  }

  @Test("Full repository name preference persists through UserDefaults")
  func fullRepositoryNamePreferencePersistsThroughUserDefaults() throws {
    let suiteName = "TaskBoardCardPreferencesTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    #expect(!TaskBoardCardPreferences.alwaysShowsFullRepositoryNames(from: userDefaults))

    TaskBoardCardPreferences.setAlwaysShowsFullRepositoryNames(true, in: userDefaults)
    userDefaults.synchronize()

    let restartedDefaults = try #require(UserDefaults(suiteName: suiteName))
    #expect(TaskBoardCardPreferences.alwaysShowsFullRepositoryNames(from: restartedDefaults))
  }

  @Test("Task Board settings use global priority badge toggle")
  func taskBoardSettingsUseGlobalPriorityBadgeToggle() throws {
    let settingsSource = try sourceFile(named: "Views/Settings/SettingsTaskBoardSection.swift")
    let cardsSource = try sourceFile(named: "Views/Settings/SettingsTaskBoardCardsSection.swift")

    #expect(settingsSource.contains("SettingsTaskBoardCardsSection()"))
    #expect(
      cardsSource.contains(
        "@AppStorage(TaskBoardCardPreferences.priorityBadgeVisibilityStorageKey)"
      )
    )
    #expect(cardsSource.contains("Toggle(\"Priority Badge\", isOn: $showsPriorityBadge)"))
    #expect(
      cardsSource.contains(
        "@AppStorage(TaskBoardCardPreferences.fullRepositoryNamesStorageKey)"
      )
    )
    #expect(
      cardsSource.contains(
        "Toggle(\"Full Repository Names\", isOn: $alwaysShowsFullRepositoryNames)"
      )
    )

    let cardsRange = try #require(settingsSource.range(of: "SettingsTaskBoardCardsSection()"))
    let laneRange = try #require(
      settingsSource.range(of: "SettingsTaskBoardLaneAppearanceSection()")
    )
    #expect(cardsRange.lowerBound < laneRange.lowerBound)
  }

  @Test("Task cards read priority badge visibility from global card preference")
  func taskCardsReadPriorityBadgeVisibilityFromGlobalCardPreference() throws {
    let laneSource = try sourceFile(named: "Views/TaskBoard/TaskBoardLaneViews.swift")
    let overviewSource = try sourceFile(named: "Views/TaskBoard/TaskBoardOverviewView.swift")
    let preferencesSource = try sourceFile(
      named: "Views/TaskBoard/TaskBoardCardPreferences.swift"
    )

    #expect(laneSource.contains("@Environment(\\.taskBoardShowsPriorityBadge)"))
    #expect(laneSource.contains("if showsPriorityBadge"))
    #expect(!laneSource.contains("laneAppearance.showsPriorityBadge"))
    #expect(
      preferencesSource.contains(
        "@AppStorage(TaskBoardCardPreferences.priorityBadgeVisibilityStorageKey)"
      )
    )
    #expect(
      preferencesSource.contains(
        ".environment(\\.taskBoardShowsPriorityBadge, showsPriorityBadge)"
      )
    )
    #expect(laneSource.contains("@Environment(\\.taskBoardAlwaysShowsFullRepositoryNames)"))
    #expect(laneSource.contains("projectLabelResolver.label("))
    #expect(
      preferencesSource.contains(
        "@AppStorage(TaskBoardCardPreferences.fullRepositoryNamesStorageKey)"
      )
    )
    #expect(
      preferencesSource.contains("\\.taskBoardAlwaysShowsFullRepositoryNames,")
    )
    #expect(preferencesSource.contains("\\.taskBoardProjectLabelResolver,"))
    #expect(overviewSource.contains(".taskBoardCardPreferences(projectLabelResolver:"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor")
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
