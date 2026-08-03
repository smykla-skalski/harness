import AppKit
import SwiftUI

#Preview("Settings Repository Task Board Scope") {
  SettingsRepositoryTaskBoardScopePreview()
    .frame(width: 1_180, height: 1_520)
    .harnessPreviewSceneAppearance()
}

struct SettingsRepositoryTaskBoardScopePreview: View {
  @State private var repositoryDraft = Self.makeRepositoryDraft()
  @State private var taskBoardDraft = Self.makeTaskBoardDraft()

  var body: some View {
    Form {
      RepositoriesMonitoredSection(
        draft: $repositoryDraft,
        taskBoardDraft: $taskBoardDraft,
        initiallyExpandedRows: ["example/harness", "example/service-02"],
        initiallyMaterializedRowCount: .max
      )
    }
    .settingsDetailFormStyle()
  }

  private static func makeRepositoryDraft() -> SettingsSharedRepositoriesDraft {
    let catalog =
      ["example/harness"]
      + (1...18).map { "example/service-\(String(format: "%02d", $0))" }
    var reviews = DashboardReviewsPreferences()
    reviews.repositoriesText = catalog.joined(separator: ", ")
    var taskBoard = TaskBoardGitSettingsDraft()
    taskBoard.githubInboxRepositoriesText = "example/harness"
    return SettingsSharedRepositoriesDraft(
      reviewsPreferences: reviews,
      taskBoardDraft: taskBoard,
      repositoryCatalog: catalog
    )
  }

  private static func makeTaskBoardDraft() -> TaskBoardGitSettingsDraft {
    var draft = TaskBoardGitSettingsDraft()
    draft.beginOverriding(.labels, for: "example/harness")
    draft.beginOverriding(.automations, for: "example/service-02")
    return draft
  }
}

public enum SettingsRepositoryTaskBoardScopePreviewRenderer {
  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    return render(
      name: "repository-task-board-scope-compact",
      size: NSSize(width: 620, height: 1_520),
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "repository-task-board-scope-wide",
        size: NSSize(width: 1_180, height: 1_520),
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        directory: directory
      )
      && render(
        name: "repository-task-board-scope-largest-text",
        size: NSSize(width: 1_300, height: 2_040),
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  @MainActor
  private static func render(
    name: String,
    size: NSSize,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let hosted =
      SettingsRepositoryTaskBoardScopePreview()
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }

    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}
