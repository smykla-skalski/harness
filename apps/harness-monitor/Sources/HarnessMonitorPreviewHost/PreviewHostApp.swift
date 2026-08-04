import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@main
struct PreviewHostApp: App {
  private let focusedTaskBoardInspectorDirectory: String?

  // Render modes stay headless unless a fixture must prove focused system chrome.
  init() {
    let environment = ProcessInfo.processInfo.environment
    focusedTaskBoardInspectorDirectory =
      environment["HARNESS_TASK_BOARD_INSPECTOR_PREVIEW_DUMP"]
    if focusedTaskBoardInspectorDirectory != nil {
      NSApplication.shared.setActivationPolicy(.regular)
      return
    }

    let renderers: [(env: String, render: @MainActor (String) -> Bool)] = [
      (
        "HARNESS_TASK_BOARD_LANE_ALIGNMENT_PREVIEW_DUMP",
        TaskBoardLaneAlignmentPreviewRenderer.dump
      ),
      ("HARNESS_TASK_BOARD_INSPECTOR_PREVIEW_DUMP", TaskBoardInspectorPreviewRenderer.dump),
      ("HARNESS_TASK_BOARD_REVIEW_REPORT_PREVIEW_DUMP", TaskBoardReviewReportPreviewRenderer.dump),
      (
        "HARNESS_TASK_BOARD_WORKFLOW_PROGRESS_PREVIEW_DUMP",
        TaskBoardWorkflowProgressPreviewRenderer.dump
      ),
      ("HARNESS_TASK_BOARD_FILTERS_PREVIEW_DUMP", TaskBoardFilterPreviewRenderer.dump),
      (
        "HARNESS_TASK_BOARD_REPOSITORY_SCOPE_PREVIEW_DUMP",
        TaskBoardRepositoryScopePreviewRenderer.dump
      ),
      (
        "HARNESS_SETTINGS_REPOSITORY_SCOPE_PREVIEW_DUMP",
        SettingsRepositoryTaskBoardScopePreviewRenderer.dump
      ),
      ("HARNESS_DASHBOARD_AGENTS_PREVIEW_DUMP", DashboardAgentsPreviewRenderer.dump),
      (
        "HARNESS_DASHBOARD_REVIEWS_TIMEOUT_PREVIEW_DUMP",
        DashboardReviewsRefreshTimeoutPreviewRenderer.dump
      ),
      ("HARNESS_TASK_BOARD_QUICK_ADD_DUMP", TaskBoardLaneQuickAddPreviewRenderer.dump),
      ("HARNESS_SECRET_MIGRATION_CONSENT_DUMP", SecretMigrationConsentPreviewRenderer.dump),
      ("HARNESS_DIFF_LAB_DUMP", Self.dumpDiffLab),
      ("HARNESS_LANE_COLOR_PICKER_DUMP", Self.dumpLaneColorPicker),
    ]
    for renderer in renderers {
      guard let dumpDirectory = environment[renderer.env] else { continue }
      NSApplication.shared.setActivationPolicy(.prohibited)
      exit(renderer.render(dumpDirectory) ? 0 : 1)
    }
    for _ in Self.forceLoadedSymbolReferences {}
  }

  @MainActor
  private static func dumpDiffLab(toDirectory directory: String) -> Bool {
    do {
      try DashboardReviewFileDiffLabRenderer.dumpFixtures(toDirectory: directory)
      return true
    } catch {
      FileHandle.standardError.write(Data("diff lab render failed: \(error)\n".utf8))
      return false
    }
  }

  @MainActor
  private static func dumpLaneColorPicker(toDirectory directory: String) -> Bool {
    do {
      try SettingsTaskBoardLaneColorPickerRenderer.dumpFixtures(toDirectory: directory)
      return true
    } catch {
      FileHandle.standardError.write(Data("lane color picker render failed: \(error)\n".utf8))
      return false
    }
  }

  var body: some Scene {
    WindowGroup("Harness Monitor Previews") {
      if let focusedTaskBoardInspectorDirectory {
        FocusedTaskBoardInspectorPreviewHost(
          outputDirectory: focusedTaskBoardInspectorDirectory
        )
      } else {
        PreviewHostContentView()
          .frame(minWidth: 900, minHeight: 600)
      }
    }
  }

  private static let forceLoadedSymbolReferences: [Any.Type] = [
    HarnessMonitorLaunchMode.self,
    PreviewFixtures.self,
  ]
}

private struct FocusedTaskBoardInspectorPreviewHost: View {
  let outputDirectory: String

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .task {
        await Task.yield()
        let succeeded = await MainActor.run {
          TaskBoardInspectorPreviewRenderer.dump(toDirectory: outputDirectory)
        }
        let completionURL = URL(fileURLWithPath: outputDirectory)
          .appendingPathComponent(".focused-preview-render-complete")
        let recordedCompletion =
          succeeded
          && (try? Data("complete\n".utf8).write(to: completionURL, options: .atomic)) != nil
        exit(recordedCompletion ? 0 : 1)
      }
  }
}

private struct PreviewHostContentView: View {
  var body: some View {
    DashboardReviewFileDiffLab()
  }
}
