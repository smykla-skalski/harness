import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@main
struct PreviewHostApp: App {
  // Headless render modes dump preview fixtures before any window or dock
  // presence appears, so verification never steals focus.
  init() {
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
      ("HARNESS_TASK_BOARD_QUICK_ADD_DUMP", TaskBoardLaneQuickAddPreviewRenderer.dump),
      ("HARNESS_SECRET_MIGRATION_CONSENT_DUMP", SecretMigrationConsentPreviewRenderer.dump),
      ("HARNESS_DIFF_LAB_DUMP", Self.dumpDiffLab),
      ("HARNESS_LANE_COLOR_PICKER_DUMP", Self.dumpLaneColorPicker),
    ]
    let environment = ProcessInfo.processInfo.environment
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
      PreviewHostContentView()
        .frame(minWidth: 900, minHeight: 600)
    }
  }

  private static let forceLoadedSymbolReferences: [Any.Type] = [
    HarnessMonitorLaunchMode.self,
    PreviewFixtures.self,
  ]
}

private struct PreviewHostContentView: View {
  var body: some View {
    DashboardReviewFileDiffLab()
  }
}
