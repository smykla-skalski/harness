import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Repository Scope") {
  TaskBoardRepositoryScopePreview()
    .harnessPreviewSceneAppearance()
}

private struct TaskBoardRepositoryScopePreview: View {
  var body: some View {
    TaskBoardOverviewView(
      snapshot: TaskBoardInboxSnapshot(),
      taskBoardItems: TaskBoardRepositoryScopePreviewFixtures.cachedItems,
      orchestratorStatus: TaskBoardRepositoryScopePreviewFixtures.orchestratorStatus,
      contentHorizontalPadding: HarnessMonitorTheme.spacingLG,
      fillsAvailableHeight: true,
      showsOperationsPanel: false,
      actions: TaskBoardOverviewActions(store: nil, scope: .dashboard),
      decisionItems: [],
      decisionsByID: [:]
    )
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct TaskBoardRepositoryScopeSummaryPreview: View {
  let localHostProjectTypes: [String]?

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.black
      TaskBoardOrchestratorPillsView(
        status: TaskBoardRepositoryScopePreviewFixtures.orchestratorStatus,
        presentation: TaskBoardOrchestratorPresentation(
          status: TaskBoardRepositoryScopePreviewFixtures.orchestratorStatus,
          taskBoardItems: TaskBoardRepositoryScopePreviewFixtures.configuredItems,
          localHostProjectTypes: localHostProjectTypes,
          repositoryScopeIsKnown: true
        )
      )
      .padding(HarnessMonitorTheme.spacingLG)
    }
  }
}

private enum TaskBoardRepositoryScopePreviewFixtures {
  static let orchestratorStatus = TaskBoardOrchestratorStatus(
    enabled: false,
    running: false,
    stepMode: true,
    currentTick: TaskBoardOrchestratorTickInfo(
      runId: "repository-scope-preview",
      phase: .completed,
      startedAt: "2026-08-03T08:00:00Z",
      completedAt: "2026-08-03T08:01:00Z",
      dryRun: true
    ),
    lastRun: lastRun,
    workflowExecutionCounts: [
      TaskBoardWorkflowExecutionCount(status: .idle, count: 1),
      TaskBoardWorkflowExecutionCount(status: .paused, count: 2),
    ],
    settings: TaskBoardOrchestratorSettings(
      stepMode: true,
      githubInbox: TaskBoardGitHubInboxConfig(
        repositories: ["smykla-skalski/harness"]
      ),
      policyVersion: "preview"
    )
  )

  static let cachedItems = [
    item(
      id: "configured-repository-task",
      title: "Visible configured repository task",
      status: .todo,
      repository: "smykla-skalski/harness",
      workflowStatus: .idle
    ),
    item(
      id: "disabled-repository-failure",
      title: "Cached task from a disabled repository",
      status: .failed,
      repository: "example/disabled",
      workflowStatus: .paused
    ),
    item(
      id: "disabled-repository-done",
      title: "Completed task from a disabled repository",
      status: .done,
      repository: "example/disabled",
      workflowStatus: .paused
    ),
  ]

  static let configuredItems = [cachedItems[0]]

  private static func item(
    id: String,
    title: String,
    status: TaskBoardStatus,
    repository: String,
    workflowStatus: TaskBoardWorkflowStatus
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: "Cached before the repository selection changed",
      status: status,
      priority: .medium,
      tags: ["repository-scope"],
      projectId: nil,
      executionRepository: repository,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: TaskBoardWorkflowState(status: workflowStatus),
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-08-03T08:00:00Z",
      updatedAt: "2026-08-03T08:10:00Z",
      deletedAt: nil
    )
  }

  private static let lastRun: TaskBoardOrchestratorRunSummary = decode(
    """
    {
      "runId": "repository-scope-preview",
      "startedAt": "2026-08-03T08:00:00Z",
      "completedAt": "2026-08-03T08:01:00Z",
      "status": "completed",
      "dryRun": true,
      "sync": { "total": 3, "providers": [], "operations": [] },
      "audit": { "total": 3, "ready": 1, "blocked": 1, "deleted": 0, "byStatus": [] },
      "evaluation": {
        "total": 3,
        "evaluated": 0,
        "updated": 0,
        "skipped": 3,
        "completed": 0,
        "running": 0,
        "reviewing": 0,
        "blocked": 0,
        "failed": 0,
        "records": [
          {
            "boardItemId": "configured-repository-task",
            "outcome": "skipped_unlinked",
            "updated": false
          },
          {
            "boardItemId": "disabled-repository-failure",
            "outcome": "skipped_unlinked",
            "updated": false
          },
          {
            "boardItemId": "disabled-repository-done",
            "outcome": "skipped_unlinked",
            "updated": false
          }
        ]
      },
      "policyTraceIds": []
    }
    """
  )

  private static func decode<T: Decodable>(_ json: String) -> T {
    do {
      return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    } catch {
      preconditionFailure("Invalid repository-scope preview fixture: \(error)")
    }
  }
}

public enum TaskBoardRepositoryScopePreviewRenderer {
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

    return renderSummary(
      name: "repository-scope-summary-default",
      size: NSSize(width: 1_100, height: 120),
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && renderSummary(
        name: "repository-scope-summary-largest-text",
        size: NSSize(width: 1_400, height: 150),
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        localHostProjectTypes: [],
        directory: directory
      )
      && renderSummary(
        name: "repository-scope-summary-routing-unavailable",
        size: NSSize(width: 1_100, height: 120),
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        localHostProjectTypes: nil,
        directory: directory
      )
      && render(
        name: "repository-scope-default",
        size: NSSize(width: 1_280, height: 720),
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        directory: directory
      )
      && render(
        name: "repository-scope-largest-text",
        size: NSSize(width: 1_560, height: 920),
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  @MainActor
  private static func renderSummary(
    name: String,
    size: NSSize,
    textSizeIndex: Int,
    localHostProjectTypes: [String]? = [],
    directory: String
  ) -> Bool {
    let content = TaskBoardRepositoryScopeSummaryPreview(
      localHostProjectTypes: localHostProjectTypes
    )
    .environment(\.harnessTextSizeIndex, textSizeIndex)
    .environment(\.fontScale, HarnessMonitorTextSize.scale(at: textSizeIndex))
    .environment(\.colorScheme, .dark)
    .environment(\.harnessControlPillTransparencyEnabled, false)
    .tint(HarnessMonitorTheme.accent)
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    let renderer = ImageRenderer(content: content)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    guard
      let image = renderer.nsImage,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:]),
      !data.isEmpty
    else {
      return false
    }
    return writeSnapshot(data: data, name: name, directory: directory)
  }

  @MainActor
  private static func render(
    name: String,
    size: NSSize,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let content = TaskBoardRepositoryScopePreview()
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    return render(content: content, name: name, size: size, directory: directory)
  }

  @MainActor
  private static func render<Content: View>(
    content: Content,
    name: String,
    size: NSSize,
    directory: String
  ) -> Bool {
    let view = NSHostingView(rootView: content)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .windowBackgroundColor
    window.isOpaque = true
    window.contentView = view
    window.orderFrontRegardless()
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    window.contentView?.displayIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    return writeSnapshot(view: view, name: name, directory: directory)
  }

  @MainActor
  private static func writeSnapshot(
    view: NSView,
    name: String,
    directory: String
  ) -> Bool {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }

    return writeSnapshot(data: data, name: name, directory: directory)
  }

  private static func writeSnapshot(
    data: Data,
    name: String,
    directory: String
  ) -> Bool {
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
