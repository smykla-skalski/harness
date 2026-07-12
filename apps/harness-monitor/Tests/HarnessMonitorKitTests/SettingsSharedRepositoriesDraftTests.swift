import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Settings shared repositories draft")
struct SettingsSharedRepositoriesDraftTests {
  @Test("Feature toggles preserve order and retain a fully disabled row")
  func featureTogglesPreserveOrderAndRetainFullyDisabledRow() throws {
    var draft = makeDraft(
      reviewsRepositories: ["example/alpha", "example/shared"],
      taskBoardRepositories: ["example/shared", "example/omega"]
    )
    let originalIDs = draft.rows.map(\.id)

    draft.setReviewsEnabled(false, for: "example/shared")
    draft.setTaskBoardEnabled(false, for: "example/shared")

    #expect(draft.rows.map(\.id) == originalIDs)
    let disabled = try #require(draft.rows.first { $0.id == "example/shared" })
    #expect(!disabled.reviewsEnabled)
    #expect(!disabled.taskBoardEnabled)
    #expect(draft.reviewsRepositories == ["example/alpha"])
    #expect(draft.taskBoardRepositories == ["example/omega"])

    draft.setTaskBoardEnabled(true, for: "example/shared")
    #expect(draft.rows.map(\.id) == originalIDs)
    #expect(draft.index(for: "example/shared") == 1)
  }

  @Test("Repository catalog preserves disabled rows and order across reloads")
  func repositoryCatalogPreservesDisabledRowsAndOrderAcrossReloads() throws {
    let catalog = ["example/omega", "example/disabled", "example/alpha"]
    let draft = makeDraft(
      reviewsRepositories: ["example/alpha"],
      taskBoardRepositories: ["example/omega"],
      repositoryCatalog: catalog
    )

    #expect(draft.rows.map(\.repositoryPath) == catalog)
    let disabled = try #require(draft.rows.first { $0.id == "example/disabled" })
    #expect(!disabled.reviewsEnabled)
    #expect(!disabled.taskBoardEnabled)

    let storedCatalog = SettingsRepositoriesCatalog.encode(draft.repositoryCatalog)
    let reloaded = makeDraft(
      reviewsRepositories: draft.reviewsRepositories,
      taskBoardRepositories: draft.taskBoardRepositories,
      repositoryCatalog: SettingsRepositoriesCatalog.decode(storedCatalog)
    )
    #expect(reloaded.rows == draft.rows)
  }

  @Test("Explicit removal preserves survivor order and rebuilds indexes")
  func explicitRemovalPreservesSurvivorOrderAndRebuildsIndexes() {
    var draft = makeDraft(
      reviewsRepositories: ["example/alpha", "example/shared"],
      taskBoardRepositories: ["example/shared", "example/omega"]
    )

    draft.remove(rowID: "example/shared")

    #expect(draft.rows.map(\.id) == ["example/alpha", "example/omega"])
    #expect(draft.index(for: "example/alpha") == 0)
    #expect(draft.index(for: "example/omega") == 1)
    #expect(draft.index(for: "example/shared") == nil)
  }

  private func makeDraft(
    reviewsRepositories: [String],
    taskBoardRepositories: [String],
    repositoryCatalog: [String] = []
  ) -> SettingsSharedRepositoriesDraft {
    var reviews = DashboardReviewsPreferences()
    reviews.repositoriesText = reviewsRepositories.joined(separator: ", ")
    var taskBoard = TaskBoardGitSettingsDraft()
    taskBoard.githubInboxRepositoriesText = taskBoardRepositories.joined(separator: "\n")
    return SettingsSharedRepositoriesDraft(
      reviewsPreferences: reviews,
      taskBoardDraft: taskBoard,
      repositoryCatalog: repositoryCatalog
    )
  }
}
