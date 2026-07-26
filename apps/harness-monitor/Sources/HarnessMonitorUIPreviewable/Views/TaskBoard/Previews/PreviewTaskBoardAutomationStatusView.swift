import AppKit
import SwiftUI

#Preview("Task Board Automation Status") {
  TaskBoardAutomationStatusPreview()
    .harnessPreviewSceneAppearance()
}

#Preview("Task Board Automation Status — Largest Text") {
  TaskBoardAutomationStatusPreview()
    .harnessPreviewSceneAppearance(
      textSizeIndex: HarnessMonitorTextSize.scales.count - 1
    )
}

private struct TaskBoardAutomationStatusPreview: View {
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    ScrollView {
      TaskBoardAutomationStatusView(
        presentation: TaskBoardAutomationStatusPreviewFixture.presentation,
        metrics: TaskBoardOverviewMetrics(fontScale: fontScale),
        isPresentationCurrent: true
      )
      .padding(24)
    }
    .frame(width: 520, height: 900)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private enum TaskBoardAutomationStatusPreviewFixture {
  static let presentation = TaskBoardAutomationPresentation(
    statePills: [
      pill("effective", "Effective", "Idle", .neutral),
      pill("desired", "Desired", "Off", .neutral),
      pill("admission", "Admission", "Stopped", .neutral),
    ],
    queueLanes: [
      queueLane(
        .waiting,
        stage("ready", "Ready", 12, .accent),
        stage("approval", "Approval", 2, .warning),
        stage("policy", "Policy blocked", 1, .danger)
      ),
      queueLane(
        .execution,
        stage("preparing", "Preparing", 3, .neutral),
        stage("starting", "Starting", 2, .accent),
        stage("active", "Active", 4, .success)
      ),
      queueLane(
        .recovery,
        stage("retrying", "Retrying", 1, .warning),
        stage("draining", "Draining", 1, .warning),
        stage("cleanup", "Cleanup", 1, .danger)
      ),
    ],
    activeRunRows: [],
    timingRows: [
      row("observed", "Observed", "in <1m", .accent),
      row("heartbeat", "Heartbeat", "2d ago"),
      row("next-run", "Next run", "4h ago"),
      row("provider-backoff", "Provider backoff", "Not scheduled"),
      row("last-success", "Last success", "Not scheduled"),
      row("reconciled", "Reconciled", "Not scheduled"),
    ],
    revisionRows: [
      row("snapshot", "Snapshot", "372859"),
      row("settings", "Settings", "6"),
      row("policy", "Policy", "1"),
    ],
    issueRows: [
      row("degraded", "Degraded / error", "None"),
      row("conflicts", "Open conflicts", "0"),
      row("failed-runs", "Failed runs", "0"),
      row("cleanup-required", "Cleanup required", "0"),
    ],
    historyRuns: [],
    detail: nil,
    metricRows: [],
    cancelTargets: [],
    cancelTargetsTruncated: false,
    controlAvailability: TaskBoardAutomationControlAvailability(
      controlBlockedReason: nil,
      forceCancelBlockedReason: nil,
      isSnapshotStale: false
    ),
    isDegraded: false
  )

  private static func pill(
    _ id: String,
    _ label: String,
    _ value: String,
    _ tone: TaskBoardAutomationTone
  ) -> TaskBoardAutomationPill {
    TaskBoardAutomationPill(id: id, label: label, value: value, tone: tone)
  }

  private static func queueLane(
    _ id: TaskBoardAutomationQueueLaneID,
    _ stages: TaskBoardAutomationQueueStage...
  ) -> TaskBoardAutomationQueueLane {
    TaskBoardAutomationQueueLane(id: id, stages: stages)
  }

  private static func stage(
    _ id: String,
    _ label: String,
    _ count: UInt,
    _ tone: TaskBoardAutomationTone
  ) -> TaskBoardAutomationQueueStage {
    TaskBoardAutomationQueueStage(
      id: id,
      label: label,
      value: count,
      tone: tone
    )
  }

  private static func row(
    _ id: String,
    _ label: String,
    _ value: String,
    _ tone: TaskBoardAutomationTone = .neutral
  ) -> TaskBoardAutomationValueRow {
    TaskBoardAutomationValueRow(id: id, label: label, value: value, tone: tone)
  }
}

@MainActor
public enum TaskBoardInspectorPreviewRenderer {
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
      name: "automation-status-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "automation-status-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  private static func render(
    name: String,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let content =
      TaskBoardAutomationStatusPreview()
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: content)
    view.setFrameSize(NSSize(width: 520, height: 900))
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
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
